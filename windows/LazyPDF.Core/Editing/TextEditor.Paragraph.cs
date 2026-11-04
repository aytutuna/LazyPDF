namespace LazyPDF.Core;

// Paragraphs: laying new text out in the lines of a block, and moving the lines of a block.
internal sealed partial class TextEditor
{
    private sealed record Line(List<EditGlyph> Glyphs, double Start, double End)
    {
        public EditGlyph First => Glyphs[0];
        public EditGlyph Last => Glyphs[^1];
    }

    private List<Line> LinesOf(TextObject block)
    {
        var lines = new List<Line>();
        var anchor = AnchorOf(block.Glyphs);
        var (ux, uy) = anchor.Direction;
        foreach (var line in block.Lines)
        {
            var glyphs = model.GlyphsIn(line.Range);
            if (glyphs.Count == 0) continue;
            var first = glyphs[0];
            double start = first.Origin.X * ux + first.Origin.Y * uy;
            lines.Add(new Line(glyphs, start, start + Extent(glyphs)));
        }
        if (lines.Count == 0) throw new EditConflictException(EditingText.NoText);
        Check(block.Glyphs);
        if (block.Glyphs.Any(g => g.Unit != anchor.Unit || g.Visit != anchor.Visit)) throw new EditConflictException(EditingText.MoreStreams);
        // A heading and the text under it are not one paragraph; laid out as one they would take the size of the first.
        if (block.Glyphs.Any(g => !char.IsWhiteSpace(g.Text.Length > 0 ? g.Text[0] : ' ') && Math.Abs(g.UserSize - anchor.UserSize) > 0.03 * anchor.UserSize)) throw new EditConflictException(EditingText.MixedSizes);
        return lines;
    }

    public void Paragraph(TextObject block, string text)
    {
        var lines = LinesOf(block);
        var anchor = AnchorOf(lines[0].Glyphs);
        var place = PlaceOf(anchor);
        double left = lines.Min(l => l.Start), right = lines.Max(l => l.End);
        bool multi = lines.Count > 1;
        double spacing = block.LineSpacing > 0 ? block.LineSpacing : anchor.UserSize * 1.2;
        double room = multi ? right - left : double.PositiveInfinity;
        var anchorFont = place.Unit.States.At(anchor.Op).Font;

        // Each line keeps its own character and word spacing and scaling, so a line is measured as the line it goes into.
        EditGlyph Line(int k) => lines[Math.Min(k, lines.Count - 1)].First;
        double Width(EditPiece p, int k)
        {
            var g = Line(k);
            return (p.Em * anchor.UserSize + (g.CharSpacing + (p.Code32 ? g.WordSpacing : 0)) * g.UnitX) * g.Scale;
        }

        var laid = new List<(List<EditPiece> Pieces, bool Last)>();
        foreach (string paragraph in text.ReplaceLineEndings("\n").Split('\n'))
        {
            var wrapped = Wrap(builder.Build(place, anchor, paragraph), room, laid.Count, Width);
            for (int i = 0; i < wrapped.Count; i++) laid.Add((wrapped[i], i == wrapped.Count - 1));
        }
        var alignment = multi ? block.Alignment : TextAlignment.Left;
        double Target(int k, double width) => alignment switch
        {
            TextAlignment.Center => (left + right) / 2 - width / 2,
            TextAlignment.Right => right - width,
            _ => k == 0 ? lines[0].Start : lines.Count > 1 ? lines[1].Start : left,
        };

        var extra = new List<(List<EditPiece> Pieces, double Start, bool Last)>();
        for (int k = 0; k < laid.Count; k++)
        {
            var (pieces, last) = laid[k];
            double width = pieces.Sum(p => Width(p, k));
            double start = Target(k, width);
            if (k >= lines.Count)
            {
                extra.Add((pieces, start, last));
                continue;
            }
            var line = lines[k];
            var at = line.First;
            double? word = alignment == TextAlignment.Justify && !last ? JustifyWord(pieces, right - left - width, at) : null;
            var font = FontFor(anchor, anchorFont, at);
            var (before, after) = Normalize(font, at, word ?? 0);
            var items = TextBuilder.Items(PlaceOf(at), at, pieces, ShiftAmount(at, start - line.Start), before, after, null, font ?? at.Unit.States.At(at.Op).Font);
            PatchOf(at).Insert(at.Element, at.Offset, items);
            CutAll(line.Glyphs, at);
        }
        for (int k = laid.Count; k < lines.Count; k++)
        {
            CutAll(lines[k].Glyphs, null);
        }
        if (extra.Count > 0)
        {
            Grew = true;
            AddLines(place, lines, anchor, anchorFont, extra, spacing);
        }
    }

    // The anchor's font at the size that gives it the anchor's size on the line of `at`; null when the line has them already.
    private static ContentOperation? FontFor(EditGlyph anchor, ContentOperation? anchorFont, EditGlyph at)
    {
        if (anchorFont is not { Operands: [PdfName name, ..] } || at.UserSize <= 0) return null;
        if (at.Font == anchor.Font && Math.Abs(at.UserSize - anchor.UserSize) <= 0.01 * anchor.UserSize) return null;
        return new ContentOperation("Tf", [name, new PdfNumber(anchor.UserSize * at.FontSize / at.UserSize)], 0, 0);
    }

    // Operators that set the font of the anchor (and widen the spaces of a justified line) for the new text of a line,
    // and the ones that put the line's own state back.
    private static (byte[]? Before, byte[]? After) Normalize(ContentOperation? font, EditGlyph at, double extraWord)
    {
        var before = new ContentWriter();
        var parts = StateParts.None;
        if (font is not null)
        {
            before.Add(font);
            parts |= StateParts.Font;
        }
        if (extraWord != 0)
        {
            before.WordSpacing(at.WordSpacing + extraWord);
            parts |= StateParts.WordSpacing;
        }
        var after = new ContentWriter();
        at.Unit.States.At(at.Op).Replay(after, parts);
        return (before.Length > 0 ? before.ToArray() : null, after.Length > 0 ? after.ToArray() : null);
    }

    // Per-space word spacing that fills the room left on a justified line; null when no space takes it.
    private static double? JustifyWord(List<EditPiece> pieces, double slack, EditGlyph at)
    {
        int spaces = pieces.Count(p => p.Code32 && p.Font is null && p.Bytes.Length == 1);
        if (spaces == 0 || slack <= 0.01) return null;
        return slack / at.UnitX / at.Scale / spaces;
    }

    // Lines after the ones the block had: their own text objects behind the one the block ends in.
    private void AddLines(Place place, List<Line> lines, EditGlyph anchor, ContentOperation? anchorFont, List<(List<EditPiece> Pieces, double Start, bool Last)> extra, double spacing)
    {
        var reference = lines[^1].First;
        var unitOps = place.Unit.Operations;
        int lastOp = lines.Max(l => l.Glyphs.Max(g => g.Op));
        int et = -1;
        for (int i = lastOp + 1; i < unitOps.Count; i++)
        {
            if (unitOps[i].Operator == "ET")
            {
                et = i;
                break;
            }
        }
        var w = new ContentWriter();
        w.Raw("");
        if (et < 0) w.Op("ET");
        w.Save();
        place.Unit.States.At(reference.Op).Replay(w, StateParts.All);
        var font = FontFor(anchor, anchorFont, reference);
        if (font is not null) w.Add(font);
        var (ux, uy) = reference.Direction;
        double referenceStart = reference.Origin.X * ux + reference.Origin.Y * uy;
        for (int e = 0; e < extra.Count; e++)
        {
            var (pieces, start, _) = extra[e];
            double along = start - referenceStart, down = (e + 1) * spacing;
            var tm = Moved(reference, ux * along + uy * down, uy * along - ux * down);
            w.BeginText().TextMatrix(tm);
            w.Raw(System.Text.Encoding.Latin1.GetString(ShowPatch.Write(TextBuilder.Items(PlaceOf(reference), reference, pieces, current: font ?? place.Unit.States.At(reference.Op).Font), false)));
            w.EndText();
        }
        w.Restore();
        int at = et >= 0 ? unitOps[et].End : unitOps[lastOp].End;
        batch.Insert(place, at, w.ToArray());
    }

    /// <summary>
    /// The text matrix that puts a glyph's origin where the origin of <paramref name="g"/> is moved
    /// to by (dx, dy) in user space: Tm' = Tm CTM T CTM^-1, since the glyph is drawn at scale Tm CTM.
    /// </summary>
    private static PdfMatrix Moved(EditGlyph g, double dx, double dy)
    {
        var ctm = g.Ctm;
        var inverse = ctm.Invert() ?? PdfMatrix.Identity;
        return g.TextMatrix.Multiply(ctm).Multiply(PdfMatrix.Translate(dx, dy)).Multiply(inverse);
    }

    // Greedy line breaking at spaces; a word wider than the room is broken between characters.
    // The line being filled is number firstLine plus the lines made so far, which is what measures it.
    private static List<List<EditPiece>> Wrap(List<EditPiece> pieces, double room, int firstLine, Func<EditPiece, int, double> measure)
    {
        var lines = new List<List<EditPiece>>();
        var line = new List<EditPiece>();
        var pending = new List<EditPiece>();
        double lineWidth = 0, pendingWidth = 0;
        double W(EditPiece p) => measure(p, firstLine + lines.Count);
        void Flush()
        {
            lines.Add(line);
            line = [];
            pending = [];
            lineWidth = pendingWidth = 0;
        }
        int i = 0;
        while (i < pieces.Count)
        {
            if (pieces[i].IsSpace)
            {
                if (line.Count > 0)
                {
                    pending.Add(pieces[i]);
                    pendingWidth += W(pieces[i]);
                }
                i++;
                continue;
            }
            int end = i;
            while (end < pieces.Count && !pieces[end].IsSpace) end++;
            var word = pieces.GetRange(i, end - i);
            if (line.Count > 0 && lineWidth + pendingWidth + word.Sum(W) > room) Flush();
            if (line.Count > 0)
            {
                line.AddRange(pending);
                lineWidth += pendingWidth;
            }
            pending = [];
            pendingWidth = 0;
            foreach (var piece in word)
            {
                double width = W(piece);
                if (line.Count > 0 && lineWidth + width > room) Flush();
                line.Add(piece);
                lineWidth += width;
            }
            i = end;
        }
        lines.Add(line);
        return lines;
    }

    public void Align(TextObject block, TextAlignment alignment)
    {
        var lines = LinesOf(block);
        var anchor = AnchorOf(lines[0].Glyphs);
        double left = lines.Min(l => l.Start), right = lines.Max(l => l.End);
        for (int k = 0; k < lines.Count; k++)
        {
            var line = lines[k];
            double width = line.End - line.Start;
            double target = alignment switch
            {
                TextAlignment.Center => (left + right) / 2 - width / 2,
                TextAlignment.Right => right - width,
                _ => left,
            };
            double shift = target - line.Start;
            var at = line.First;
            var items = new List<ShowItem>();
            if (Math.Abs(shift) > 0.01) items.Add(new ShowShift(-ShiftAmount(at, shift)));
            PatchOf(at).Insert(at.Element, at.Offset, items);
            if (alignment != TextAlignment.Justify || k == lines.Count - 1) continue;
            int spaces = line.Glyphs.Count(g => g.Character.IsSpace);
            double slack = right - left - width;
            if (spaces == 0 || slack <= 0.01) continue;
            if (!Balanced(at.Unit, at.Op, line.Last.Op)) throw new EditConflictException(EditingText.Unbalanced);
            var set = new ContentWriter().WordSpacing(at.WordSpacing + slack / at.UnitX / at.Scale / spaces);
            var restore = new ContentWriter();
            line.Last.Unit.States.At(line.Last.Op).Replay(restore, StateParts.WordSpacing);
            PatchOf(at).Insert(at.Element, at.Offset, [new ShowOps(set.ToArray())]);
            PatchOf(line.Last).Insert(line.Last.Element, line.Last.Offset + line.Last.Length, [new ShowOps(restore.ToArray())]);
        }
    }

    public void Space(TextObject block, double spacing)
    {
        var lines = LinesOf(block);
        double old = block.LineSpacing;
        if (lines.Count < 2 || old <= 0 || spacing <= 0) throw new EditConflictException(EditingText.NoText);
        for (int k = 1; k < lines.Count; k++)
        {
            var (first, last) = (lines[k].First, lines[k].Last);
            if (!Balanced(first.Unit, first.Op, last.Op)) throw new EditConflictException(EditingText.Unbalanced);
            var m = first.TextMatrix.Multiply(first.Ctm);
            double vertical = Math.Sqrt(m.C * m.C + m.D * m.D);
            var (ux, uy) = first.Direction;
            double sign = Math.Sign(m.C * -uy + m.D * ux);
            if (vertical < 1e-9 || sign == 0) continue;
            var set = new ContentWriter().Op("Ts", first.Rise + sign * k * (old - spacing) / vertical);
            var restore = new ContentWriter();
            last.Unit.States.At(last.Op).Replay(restore, StateParts.Rise);
            PatchOf(first).Insert(first.Element, first.Offset, [new ShowOps(set.ToArray())]);
            PatchOf(last).Insert(last.Element, last.Offset + last.Length, [new ShowOps(restore.ToArray())]);
        }
    }
}
