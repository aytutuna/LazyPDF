namespace LazyPDF.Core;

/// <summary>
/// Characters of a page picked by a drag, a rectangle or a click, as runs of indices in reading
/// order. Points and rectangles are in user space; the viewer converts from display points with
/// <see cref="PageGeometry"/>.
/// </summary>
public sealed class TextSelection
{
    private TextSelection(TextPage page, IReadOnlyList<TextRange> ranges)
    {
        Page = page;
        Ranges = ranges;
    }

    public TextPage Page { get; }
    public IReadOnlyList<TextRange> Ranges { get; }
    public bool IsEmpty => Ranges.Count == 0;

    /// <summary>The characters between two insertion points, as dragging a caret from the first to the second selects them. Either order.</summary>
    public static TextSelection Between(TextPage page, double x1, double y1, double x2, double y2)
    {
        int a = page.CaretAt(x1, y1), b = page.CaretAt(x2, y2);
        return Of(page, new TextRange(Math.Min(a, b), Math.Max(a, b)));
    }

    /// <summary>The characters whose boxes lie at least half inside a rectangle (a marquee), by lines in reading order.</summary>
    public static TextSelection InRectangle(TextPage page, PdfRect rect)
    {
        var ranges = new List<TextRange>();
        int start = -1;
        for (int i = 0; i <= page.Chars.Count; i++)
        {
            bool inside = i < page.Chars.Count && Covered(page.Chars[i].Quad, rect);
            if (inside && start < 0) start = i;
            else if (!inside && start >= 0)
            {
                ranges.Add(new TextRange(start, i));
                start = -1;
            }
        }
        return new TextSelection(page, ranges);
    }

    /// <summary>The word under a point; a point on a space takes the word after it, else the one before it.</summary>
    public static TextSelection WordAt(TextPage page, double x, double y)
    {
        if (page.HitTest(x, y) is not { } hit) return new TextSelection(page, []);
        var c = page.Chars[hit.Char];
        if (c.Word >= 0) return Of(page, page.WordRange(c.Word));
        var line = page.Lines[c.Line].Range;
        for (int i = hit.Char; i < line.End; i++)
        {
            if (page.Chars[i].Word >= 0) return Of(page, page.WordRange(page.Chars[i].Word));
        }
        for (int i = hit.Char; i >= line.Start; i--)
        {
            if (page.Chars[i].Word >= 0) return Of(page, page.WordRange(page.Chars[i].Word));
        }
        return new TextSelection(page, []);
    }

    /// <summary>The line under a point (a triple click).</summary>
    public static TextSelection LineAt(TextPage page, double x, double y) =>
        page.HitTest(x, y) is { } hit ? Of(page, page.LineRange(hit.Line)) : new TextSelection(page, []);

    public static TextSelection Of(TextPage page, TextRange range)
    {
        int start = Math.Clamp(range.Start, 0, page.Chars.Count), end = Math.Clamp(range.End, start, page.Chars.Count);
        return new TextSelection(page, start == end ? [] : [new TextRange(start, end)]);
    }

    /// <summary>The selected text; runs that are not next to each other are separated by a line feed.</summary>
    public string GetText(bool joinHyphens = false) =>
        string.Join("\n", Ranges.Select(r => Page.GetText(r, joinHyphens)));

    /// <summary>One box per stretch of a line, for painting.</summary>
    public IReadOnlyList<TextQuad> Quads() => [.. Ranges.SelectMany(Page.Quads)];

    private static bool Covered(TextQuad quad, PdfRect rect)
    {
        var b = quad.Bounds;
        if (b.Width <= 0 || b.Height <= 0)
        {
            var (cx, cy) = quad.Center;
            return cx >= rect.Left && cx <= rect.Right && cy >= rect.Bottom && cy <= rect.Top;
        }
        double w = Math.Min(b.Right, rect.Right) - Math.Max(b.Left, rect.Left);
        double h = Math.Min(b.Top, rect.Top) - Math.Max(b.Bottom, rect.Bottom);
        return w > 0 && h > 0 && w * h >= 0.5 * b.Width * b.Height;
    }
}
