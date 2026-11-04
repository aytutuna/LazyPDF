namespace LazyPDF.Core;

/// <summary>What to change about the look of some text; a null member is left as it is.</summary>
/// <param name="Family">A font family, looked up through the editor's <see cref="IFontSource"/>.</param>
/// <param name="Bold">Bold on or off. With <paramref name="Italic"/> and <paramref name="Family"/> this picks a new font for the text.</param>
/// <param name="Size">Font size in text space units (what <c>Tf</c> takes).</param>
/// <param name="CharSpacing">Extra space after each character, in text space units (<c>Tc</c>).</param>
public sealed record TextStyleChange(string? Family = null, bool? Bold = null, bool? Italic = null, double? Size = null, RgbColor? Color = null, double? CharSpacing = null)
{
    internal bool NeedsFont => Family is not null || Bold is not null || Italic is not null;
}

/// <summary>Changes the text of a <see cref="PageModel"/> into an <see cref="EditBatch"/>; nothing is written until the batch is applied.</summary>
internal sealed partial class TextEditor(PageModel model, EditBatch batch, TextBuilder builder, IFontSource? fonts)
{
    public bool Grew { get; private set; }
    public bool Overlaps { get; private set; }

    private static Place PlaceOf(EditGlyph g) => new(g.Unit, g.Visit);

    private ShowPatch PatchOf(EditGlyph g) => batch.Patch(PlaceOf(g), g.Op) ?? throw new EditConflictException(EditingText.SharedForm);

    private static void Check(IEnumerable<EditGlyph> glyphs)
    {
        foreach (var g in glyphs)
        {
            if (g.Font.IsVertical) throw new EditConflictException(EditingText.Vertical);
            if (g.HasActualText) throw new EditConflictException(EditingText.ActualText);
        }
    }

    // Text after a cut keeps its place, by a move forward of the width cut, except in the run the new text goes into
    // (the run of flow), where it follows the new text.
    private void CutAll(IReadOnlyList<EditGlyph> glyphs, EditGlyph? flow)
    {
        var all = glyphs.SelectMany(g => g.Twins.Prepend(g)).ToList();
        foreach (var g in all) PatchOf(g).Cut(g.Element, g.Offset, g.Offset + g.Length);
        var flows = flow is null ? [] : flow.Twins.Prepend(flow).ToList();
        foreach (var group in Runs([.. all.Where(g => !flows.Any(f => SameRun(f, g)))]))
        {
            var first = group[0];
            double amount = -group.Sum(g => g.Advance) * 1000 / (first.FontSize * first.Scale);
            if (double.IsFinite(amount) && Math.Abs(amount) > 1e-6) PatchOf(first).Insert(first.Element, first.Offset, [new ShowShift(amount)]);
        }
    }

    private static EditGlyph AnchorOf(IReadOnlyList<EditGlyph> glyphs) =>
        glyphs.FirstOrDefault(g => g.Text.Any(c => !char.IsWhiteSpace(c))) ?? glyphs[0];

    /// <summary>Replaces the glyphs of a range of characters with <paramref name="text"/> in their font, at the place of the first of them.</summary>
    public void Replace(TextRange range, string text, TextStyleChange? style = null)
    {
        var glyphs = model.GlyphsIn(range);
        if (glyphs.Count == 0) throw new EditConflictException(EditingText.NoText);
        Check(glyphs);
        if (style is null && StyleGroups(glyphs) is { Count: > 1 } groups)
        {
            ReplaceByStyle(range, glyphs, groups, text);
            return;
        }
        var anchor = AnchorOf(glyphs);
        var pieces = Pieces(PlaceOf(glyphs[0]), glyphs[0], anchor, text, style, out var wrap);
        double newWidth = pieces.Sum(p => p.Advance) * anchor.UnitX;
        double shift = AlignmentShift(range, glyphs, newWidth);
        PutText(glyphs[0], false, pieces, wrap, shift);
        foreach (var twin in glyphs[0].Twins) PutText(twin, false, pieces, wrap, shift);
        CutAll(glyphs, glyphs[0]);
        CheckRoom(range, glyphs, newWidth);
    }

    // A word set partly in another size, font or colour (a drop cap, a changed letter) takes its new letters in the same parts.
    private void ReplaceByStyle(TextRange range, List<EditGlyph> glyphs, List<List<EditGlyph>> groups, string text)
    {
        var runes = text.EnumerateRunes().Select(r => r.ToString()).ToList();
        int next = 0;
        double width = 0;
        for (int i = 0; i < groups.Count; i++)
        {
            var group = groups[i];
            int take = i == groups.Count - 1 ? runes.Count - next : Math.Min(group.Count, runes.Count - next);
            string part = string.Concat(runes.Skip(next).Take(take));
            next += take;
            if (part.Length == 0)
            {
                CutAll(group, null);
                continue;
            }
            var anchor = AnchorOf(group);
            var pieces = builder.Build(PlaceOf(group[0]), anchor, part);
            PutText(group[0], false, pieces, default, 0);
            foreach (var twin in group[0].Twins) PutText(twin, false, pieces, default, 0);
            CutAll(group, group[0]);
            width += pieces.Sum(p => p.Advance) * anchor.UnitX;
        }
        CheckRoom(range, glyphs, width);
    }

    private static List<List<EditGlyph>> StyleGroups(List<EditGlyph> glyphs)
    {
        var groups = new List<List<EditGlyph>>();
        foreach (var g in glyphs)
        {
            if (groups.Count > 0 && groups[^1][^1] is { } last && last.Font == g.Font && last.Color == g.Color && Math.Abs(last.UserSize - g.UserSize) < 0.01 * last.UserSize)
                groups[^1].Add(g);
            else groups.Add([g]);
        }
        return groups;
    }

    /// <summary>Adds text before the character <paramref name="index"/>, or after the last one when it is past the end.</summary>
    public void Insert(int index, string text)
    {
        var chars = model.Text.Chars;
        EditGlyph? glyph = null;
        bool after = false;
        for (int i = Math.Min(index, chars.Count - 1); i >= 0 && glyph is null; i--)
        {
            glyph = model.CharGlyphs[i];
            after = i < index;
        }
        for (int i = index; i < chars.Count && glyph is null; i++) glyph = model.CharGlyphs[i];
        if (glyph is null) throw new EditConflictException(EditingText.NoText);
        Check([glyph]);
        var pieces = Pieces(PlaceOf(glyph), glyph, glyph, text, null, out var wrap);
        PutText(glyph, after, pieces, wrap, 0);
    }

    // Removes the glyphs and moves what follows them in the same string back to where it was.
    public void Delete(TextRange range)
    {
        var glyphs = model.GlyphsIn(range);
        if (glyphs.Count == 0) throw new EditConflictException(EditingText.NoText);
        Check(glyphs);
        CutAll(glyphs, null);
    }

    // Glyphs that are neighbours in one string.
    private static List<List<EditGlyph>> Runs(IReadOnlyList<EditGlyph> glyphs)
    {
        var runs = new List<List<EditGlyph>>();
        foreach (var g in glyphs)
        {
            if (runs.Count > 0 && runs[^1][^1] is { } last && last.Unit == g.Unit && last.Op == g.Op && last.Element == g.Element && last.Offset + last.Length == g.Offset)
                runs[^1].Add(g);
            else runs.Add([g]);
        }
        return runs;
    }

    private void PutText(EditGlyph at, bool after, List<EditPiece> pieces, StyleWrap wrap, double shift)
    {
        var items = TextBuilder.Items(PlaceOf(at), at, pieces, ShiftAmount(at, shift), wrap.Before, wrap.After, wrap.Size);
        PatchOf(at).Insert(at.Element, at.Offset + (after ? at.Length : 0), items);
    }

    /// <summary>Thousandths of the font size for a shift along the line, in user space units.</summary>
    private static double ShiftAmount(EditGlyph g, double shift) => shift == 0 ? 0 : shift / g.UnitX * 1000 / (g.FontSize * g.Scale);

    /// <summary>The operators round new text that change its look, and the size it is set at.</summary>
    internal readonly record struct StyleWrap(byte[]? Before, byte[]? After, double? Size);

    private List<EditPiece> Pieces(Place place, EditGlyph at, EditGlyph anchor, string text, TextStyleChange? style, out StyleWrap wrap)
    {
        wrap = default;
        if (style is null) return builder.Build(place, anchor, text);
        var state = place.Unit.States.At(at.Op);
        var before = new ContentWriter();
        var after = new ContentWriter();
        var restore = StateParts.None;
        double? size = null;
        if (style.Color is { } color)
        {
            before.FillRgb(color.R / 255.0, color.G / 255.0, color.B / 255.0);
            if (at.RenderMode is 1 or 2) before.StrokeRgb(color.R / 255.0, color.G / 255.0, color.B / 255.0);
            restore |= StateParts.Fill | (at.RenderMode is 1 or 2 ? StateParts.Stroke : 0);
        }
        if (style.CharSpacing is { } tc)
        {
            before.CharSpacing(tc);
            restore |= StateParts.CharSpacing;
        }
        List<EditPiece> pieces;
        if (style.NeedsFont)
        {
            if (state.Font is null) throw new EditConflictException(EditingText.FontSetOutside);
            size = style.Size ?? at.FontSize;
            var draw = StandIn(anchor.Font, style, text);
            string name = batch.AddResource(place, "Font", draw.Reference) ?? throw new EditConflictException(EditingText.SharedForm);
            pieces = TextBuilder.BuildWith(draw, name, anchor, text, size.Value);
        }
        else
        {
            pieces = builder.Build(place, anchor, text);
            if (style.Size is { } newSize)
            {
                if (state.Font is null || state.Font.Operands.Count == 0 || state.Font.Operands[0] is not PdfName fontName) throw new EditConflictException(EditingText.FontSetOutside);
                before.Font(fontName.Value, newSize);
                restore |= StateParts.Font;
                double factor = newSize / at.FontSize;
                pieces = [.. pieces.Select(p => new EditPiece { Text = p.Text, Bytes = p.Bytes, Font = p.Font, IsSpace = p.IsSpace, Shift = p.Shift, Advance = p.Advance * factor })];
            }
        }
        if (restore != StateParts.None) state.Replay(after, restore);
        wrap = new StyleWrap(before.Length > 0 ? before.ToArray() : null, after.Length > 0 ? after.ToArray() : null, size);
        return pieces;
    }

    // A font of the family and style the change asks for; bold and italic start from those of the font in the file.
    private PdfDrawFont StandIn(PdfFont font, TextStyleChange change, string text)
    {
        if (fonts is null) throw new EditConflictException(EditingText.NoFont);
        var (families, current) = FontMatch.For(font);
        var style = FontStyles.Regular;
        if (change.Bold ?? current.HasFlag(FontStyles.Bold)) style |= FontStyles.Bold;
        if (change.Italic ?? current.HasFlag(FontStyles.Italic)) style |= FontStyles.Italic;
        var candidates = change.Family is { } family ? new List<string> { family } : families.ToList();
        var embedder = new PdfFontEmbedder(model.Document, fonts);
        foreach (string candidate in candidates)
        {
            if (embedder.Add(candidate, style, [text], embed: font.IsEmbedded) is { } draw)
            {
                if (draw.Missing.Count > 0) throw new EditConflictException(string.Format(EditingText.NoGlyphs, string.Concat(draw.Missing.Select(char.ConvertFromUtf32))));
                return draw;
            }
        }
        throw new EditConflictException(EditingText.NoFont);
    }

    /// <summary>Changes the look of the text of a range without changing its characters where the font stays the same.</summary>
    public void Restyle(TextRange range, TextStyleChange change)
    {
        var glyphs = model.GlyphsIn(range);
        if (glyphs.Count == 0) throw new EditConflictException(EditingText.NoText);
        Check(glyphs);
        if (change.NeedsFont)
        {
            Replace(range, model.Text.GetText(range), change);
            return;
        }
        foreach (var group in glyphs.GroupBy(g => (g.Unit, g.Visit)))
        {
            var list = group.ToList();
            var (a, b) = (list[0], list[^1]);
            var place = PlaceOf(a);
            if (!Balanced(a.Unit, a.Op, b.Op)) throw new EditConflictException(EditingText.Unbalanced);
            var state = a.Unit.States.At(a.Op);
            var before = new ContentWriter();
            var restore = StateParts.None;
            if (change.Size is { } size)
            {
                if (state.Font is null || state.Font.Operands.Count == 0 || state.Font.Operands[0] is not PdfName name) throw new EditConflictException(EditingText.FontSetOutside);
                before.Font(name.Value, size);
                restore |= StateParts.Font;
            }
            if (change.Color is { } c)
            {
                before.FillRgb(c.R / 255.0, c.G / 255.0, c.B / 255.0);
                restore |= StateParts.Fill;
                if (a.RenderMode is 1 or 2)
                {
                    before.StrokeRgb(c.R / 255.0, c.G / 255.0, c.B / 255.0);
                    restore |= StateParts.Stroke;
                }
            }
            if (change.CharSpacing is { } tc)
            {
                before.CharSpacing(tc);
                restore |= StateParts.CharSpacing;
            }
            var after = new ContentWriter();
            b.Unit.States.At(b.Op).Replay(after, restore);
            PatchOf(a).Insert(a.Element, a.Offset, [new ShowOps(before.ToArray())]);
            PatchOf(b).Insert(b.Element, b.Offset + b.Length, [new ShowOps(after.ToArray())]);
        }
    }

    /// <summary>The operations from <paramref name="first"/> to <paramref name="last"/> open and close the same q levels, so that an operator put round them cannot leak.</summary>
    internal static bool Balanced(ContentUnit unit, int first, int last)
    {
        var states = unit.States;
        int depth = states.At(first).Depth;
        for (int i = first; i <= last; i++)
        {
            if (states.At(i).Depth < depth) return false;
        }
        return states.At(last + 1).Depth == depth;
    }

    private double AlignmentShift(TextRange range, IReadOnlyList<EditGlyph> glyphs, double newWidth)
    {
        int first = FirstChar(range);
        if (first < 0) return 0;
        var line = model.Text.Lines[model.Text.Chars[first].Line];
        var lineGlyphs = model.GlyphsIn(line.Range);
        if (lineGlyphs.Count != glyphs.Count || model.AlignmentOfLine(line.Index) is not { } alignment || alignment is TextAlignment.Left or TextAlignment.Justify) return 0;
        double oldWidth = Extent(glyphs);
        return alignment == TextAlignment.Right ? oldWidth - newWidth : (oldWidth - newWidth) / 2;
    }

    private int FirstChar(TextRange range)
    {
        for (int i = Math.Max(range.Start, 0); i < Math.Min(range.End, model.CharGlyphs.Length); i++)
        {
            if (model.CharGlyphs[i] is not null) return i;
        }
        return -1;
    }

    /// <summary>Length along the first glyph's baseline from its origin to the end of the last glyph.</summary>
    private static double Extent(IReadOnlyList<EditGlyph> glyphs)
    {
        var (ux, uy) = glyphs[0].Direction;
        var last = glyphs[^1];
        return (last.Origin.X - glyphs[0].Origin.X) * ux + (last.Origin.Y - glyphs[0].Origin.Y) * uy + last.Advance * last.UnitX;
    }

    // Later text on the line that is not part of the run does not move, so new text that grows can run into it.
    private void CheckRoom(TextRange range, IReadOnlyList<EditGlyph> glyphs, double newWidth)
    {
        double oldWidth = Extent(glyphs);
        if (newWidth <= oldWidth + 0.01) return;
        var first = glyphs[0];
        var last = glyphs[^1];
        var (ux, uy) = first.Direction;
        double start = first.Origin.X * ux + first.Origin.Y * uy;
        double end = start + newWidth;
        for (int i = range.End; i < Math.Min(model.CharGlyphs.Length, range.End + 400); i++)
        {
            if (model.CharGlyphs[i] is not { } next || next.Text.All(char.IsWhiteSpace)) continue;
            double across = Math.Abs((next.Origin.X - first.Origin.X) * -uy + (next.Origin.Y - first.Origin.Y) * ux);
            double nextStart = next.Origin.X * ux + next.Origin.Y * uy;
            if (across > 0.3 * first.UserSize || nextStart < start) continue;
            if (SameRun(last, next)) return;
            if (end > nextStart - 0.05 * first.UserSize) Overlaps = true;
            return;
        }
        var box = model.Page.CropBox;
        var (ex, ey) = (first.Origin.X + ux * newWidth, first.Origin.Y + uy * newWidth);
        if (ex > box.Right || ex < box.Left || ey > box.Top || ey < box.Bottom) Overlaps = true;
    }

    // Both are shown one after the other with no new position set between them.
    private static bool SameRun(EditGlyph a, EditGlyph b)
    {
        if (a.Unit != b.Unit || b.Op < a.Op) return false;
        var ops = a.Unit.Operations;
        for (int i = a.Op + 1; i <= b.Op && i < ops.Count; i++)
        {
            if (ops[i].Operator is "Td" or "TD" or "Tm" or "T*" or "'" or "\"" or "BT" or "ET") return false;
        }
        return true;
    }
}
