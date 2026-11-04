namespace LazyPDF.Core;

/// <summary>
/// A page read for editing: its text as <see cref="TextPage"/> lays it out, its glyphs, images and
/// paths with the streams and operations they came from, and the selectable objects built from them.
/// </summary>
internal sealed class PageModel
{
    private PageModel(PdfDocument document, PdfPage page, EditScan scan, TextPage text)
    {
        Document = document;
        Page = page;
        Scan = scan;
        Text = text;
        CharGlyphs = new EditGlyph?[text.Chars.Count];
    }

    public PdfDocument Document { get; }
    public PdfPage Page { get; }
    public EditScan Scan { get; }
    public TextPage Text { get; }

    /// <summary>The glyph behind each character of <see cref="TextPage.Chars"/>; null for an implied space or a character the content does not show as such.</summary>
    public EditGlyph?[] CharGlyphs { get; }

    public List<PageObject> Objects { get; } = [];

    private Dictionary<(ContentUnit, int), List<EditGlyph>>? _byOp;

    /// <summary>The glyphs one operation shows.</summary>
    public IReadOnlyList<EditGlyph> GlyphsAt(ContentUnit unit, int op)
    {
        if (_byOp is null)
        {
            _byOp = [];
            foreach (var g in Scan.Glyphs)
            {
                if (!_byOp.TryGetValue((g.Unit, g.Op), out var list)) _byOp[(g.Unit, g.Op)] = list = [];
                list.Add(g);
            }
        }
        return _byOp.TryGetValue((unit, op), out var found) ? found : [];
    }

    /// <summary>A glyph that is not in <paramref name="own"/> is shown between <paramref name="a"/> and <paramref name="b"/>, in their strings or the ones between.</summary>
    public bool ForeignBetween(ContentUnit unit, EditGlyph a, EditGlyph b, HashSet<EditGlyph> own)
    {
        for (int op = a.Op; op <= b.Op; op++)
        {
            foreach (var g in GlyphsAt(unit, op))
            {
                if (own.Contains(g)) continue;
                bool afterA = op > a.Op || (g.Element, g.Offset).CompareTo((a.Element, a.Offset)) > 0;
                bool beforeB = op < b.Op || (g.Element, g.Offset).CompareTo((b.Element, b.Offset)) < 0;
                if (afterA && beforeB) return true;
            }
        }
        return false;
    }

    private readonly Dictionary<int, TextAlignment> _lineAlignment = [];

    public TextAlignment? AlignmentOfLine(int line) => _lineAlignment.TryGetValue(line, out var a) ? a : null;

    public static PageModel Load(PdfDocument document, int pageIndex)
    {
        var page = document.Pages[pageIndex];
        var scan = new EditScan(document, page);
        new ContentInterpreter(document) { WalkPatterns = false }.Run(page, scan);
        var text = TextPage.Create(document, page);
        text.RequirePageContent();
        var model = new PageModel(document, page, scan, text);
        model.MapChars();
        model.BuildObjects();
        return model;
    }

    private void MapChars()
    {
        var byKey = new Dictionary<(PdfStream?, int, int, int), List<EditGlyph>>();
        foreach (var g in Scan.Glyphs)
        {
            var key = (g.Unit.Form, g.Op, g.Element, g.Offset);
            if (!byKey.TryGetValue(key, out var list)) byKey[key] = list = [];
            list.Add(g);
        }
        var claimed = new HashSet<EditGlyph>();
        foreach (var c in Text.Chars)
        {
            if (c.OperatorIndex < 0 || !byKey.TryGetValue((c.Form, c.OperatorIndex, c.Element, c.Offset), out var list)) continue;
            var center = c.Quad.Center;
            EditGlyph? best = null;
            double distance = double.MaxValue;
            foreach (var g in list)
            {
                var gc = g.Quad.Center;
                double d = Math.Abs(gc.X - center.X) + Math.Abs(gc.Y - center.Y);
                if (d < distance && !claimed.Contains(g))
                {
                    distance = d;
                    best = g;
                }
            }
            if (best is null) continue;
            claimed.Add(best);
            CharGlyphs[c.Index] = best;
        }
        AttachTwins(claimed);
    }

    // A glyph drawn again at nearly the same place is dropped from the text; it is cut with the one it copies.
    private void AttachTwins(HashSet<EditGlyph> claimed)
    {
        if (claimed.Count == Scan.Glyphs.Count) return;
        const double cell = 4;
        var grid = new Dictionary<(long, long), List<EditGlyph>>();
        foreach (var g in claimed)
        {
            var key = ((long)Math.Floor(g.Matrix.E / cell), (long)Math.Floor(g.Matrix.F / cell));
            if (!grid.TryGetValue(key, out var list)) grid[key] = list = [];
            list.Add(g);
        }
        foreach (var g in Scan.Glyphs)
        {
            if (claimed.Contains(g) || g.Text.Length == 0 || g.HasActualText) continue;
            long cx = (long)Math.Floor(g.Matrix.E / cell), cy = (long)Math.Floor(g.Matrix.F / cell);
            for (long i = cx - 1; i <= cx + 1; i++)
            {
                for (long j = cy - 1; j <= cy + 1; j++)
                {
                    if (!grid.TryGetValue((i, j), out var list)) continue;
                    foreach (var other in list)
                    {
                        if (other.Text == g.Text && Math.Abs(other.Matrix.E - g.Matrix.E) < 0.2 * other.UserSize && Math.Abs(other.Matrix.F - g.Matrix.F) < 0.2 * other.UserSize)
                        {
                            other.Twins.Add(g);
                            goto next;
                        }
                    }
                }
            }
        next:;
        }
    }

    private void BuildObjects()
    {
        var found = new List<(int Sequence, Func<int, PageObject> Make)>();
        foreach (var block in Text.Blocks)
        {
            var glyphs = BlockGlyphs(block);
            if (glyphs.Count == 0) continue;
            found.Add((glyphs.Max(g => g.Sequence), id => MakeText(id, block, glyphs)));
        }
        foreach (var image in Scan.Images)
        {
            found.Add((image.Sequence, id => new ImageObject(id, Shown(image), image.Unit, image.Visit, image.Sequence, image.Info, image.Opacity, image.Op)));
        }
        foreach (var path in Scan.Paths)
        {
            found.Add((path.Sequence, id => new PathObject(id, path.Info.InkBounds, path.Unit, path.Visit, path.Sequence, path.Info, path.Style, path.FirstOp, path.PaintOp)));
        }
        foreach (var (_, make) in found.OrderBy(f => f.Sequence)) Objects.Add(make(Objects.Count));
    }

    public TextRange BlockChars(TextBlock block)
    {
        if (block.Lines.IsEmpty) return default;
        return new TextRange(Text.Lines[block.Lines.Start].Range.Start, Text.Lines[block.Lines.End - 1].Range.End);
    }

    public List<EditGlyph> BlockGlyphs(TextBlock block) => GlyphsIn(BlockChars(block));

    public List<EditGlyph> GlyphsIn(TextRange range)
    {
        var list = new List<EditGlyph>();
        for (int i = Math.Max(range.Start, 0); i < Math.Min(range.End, CharGlyphs.Length); i++)
        {
            if (CharGlyphs[i] is { } g) list.Add(g);
        }
        return list;
    }

    // The part of a picture a clip leaves showing, which is what a person sees and grabs.
    private static PdfRect Shown(ImageRecord image)
    {
        var shown = image.Info.Bounds.Intersect(image.Clip);
        return shown.IsEmpty ? image.Info.Bounds : shown;
    }

    private TextObject MakeText(int id, TextBlock block, List<EditGlyph> glyphs)
    {
        var first = glyphs.FirstOrDefault(g => !char.IsWhiteSpace(g.Text.Length > 0 ? g.Text[0] : ' ')) ?? glyphs[0];
        var lines = new List<TextObjectLine>();
        for (int i = block.Lines.Start; i < block.Lines.End; i++)
        {
            var line = Text.Lines[i];
            lines.Add(new TextObjectLine(line.Index, line.Range, line.Text, line.Bounds));
        }
        var chars = BlockChars(block);
        var (alignment, spacing) = BlockLayout.Detect(Text, block, Scan.Glyphs.Count > 0 ? first : null, this);
        for (int i = block.Lines.Start; i < block.Lines.End; i++) _lineAlignment[i] = alignment;
        return new TextObject(id, block.Bounds, first.Unit, first.Visit, glyphs.Max(g => g.Sequence), block)
        {
            Glyphs = glyphs,
            Lines = lines,
            Text = Text.GetText(chars),
            Range = chars,
            Font = first.Font,
            Size = first.UserSize,
            Color = first.Color,
            CharSpacing = first.CharSpacing,
            Alignment = alignment,
            LineSpacing = spacing,
        };
    }
}

/// <summary>Alignment and line spacing of a block, read from where its lines start and end.</summary>
internal static class BlockLayout
{
    public static (TextAlignment Alignment, double Spacing) Detect(TextPage text, TextBlock block, EditGlyph? anchor, PageModel model)
    {
        if (anchor is null || block.Lines.Count == 0) return (TextAlignment.Left, 0);
        var (ux, uy) = anchor.Direction;
        double size = Math.Max(anchor.UserSize, 1);
        var starts = new List<double>();
        var ends = new List<double>();
        var origins = new List<(double X, double Y)>();
        for (int i = block.Lines.Start; i < block.Lines.End; i++)
        {
            var q = text.Lines[i].Quad;
            starts.Add(q.X0 * ux + q.Y0 * uy);
            ends.Add(q.X1 * ux + q.Y1 * uy);
            var glyph = model.GlyphsIn(text.Lines[i].Range).FirstOrDefault();
            if (glyph is not null) origins.Add(glyph.Origin);
        }
        double spacing = origins.Count > 1 ? Math.Abs((origins[1].X - origins[0].X) * -uy + (origins[1].Y - origins[0].Y) * ux) : 0;
        if (starts.Count < 2) return (TextAlignment.Left, spacing);
        double tol = 0.6 * size;
        bool Same(IEnumerable<double> values, double within) => values.Max() - values.Min() <= within;
        var centers = starts.Zip(ends, (a, b) => (a + b) / 2).ToList();
        if (Same(starts, tol))
        {
            // The last line of a justified paragraph is short.
            if (starts.Count >= 3 && Same(ends.Take(ends.Count - 1), 0.15 * size)) return (TextAlignment.Justify, spacing);
            return (TextAlignment.Left, spacing);
        }
        if (Same(ends, tol)) return (TextAlignment.Right, spacing);
        if (Same(centers, tol)) return (TextAlignment.Center, spacing);
        return (TextAlignment.Left, spacing);
    }
}
