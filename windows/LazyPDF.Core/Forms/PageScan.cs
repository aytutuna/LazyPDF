namespace LazyPDF.Core;

internal sealed record ScanGlyph(PdfRect Box, string Text);

internal sealed record ScanRun(PdfRect Box, string Text, IReadOnlyList<ScanGlyph> Glyphs);

/// <summary>What a page draws that matters to finding blanks: glyphs, ruling lines, boxes and circles, all in user space.</summary>
internal sealed class PageScan : ContentVisitor
{
    private const int MaxItems = 200_000;
    private const double Thin = 1.6;
    private const double Tolerance = 0.6;

    public List<ScanGlyph> Glyphs { get; } = [];
    public List<(double Y, double X1, double X2)> Horizontal { get; } = [];
    public List<(double X, double Y1, double Y2)> Vertical { get; } = [];
    public List<PdfRect> Boxes { get; } = [];
    public List<PdfRect> Circles { get; } = [];

    public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
    {
        if (Glyphs.Count < MaxItems && glyph.Unicode is { Length: > 0 } text && context.State.RenderMode != 3 && !glyph.Bounds.IsEmpty)
        {
            Glyphs.Add(new ScanGlyph(glyph.Bounds, text));
        }
    }

    public override void PaintPath(ContentContext context, PathInfo path)
    {
        if (!path.Fill && !path.Stroke) return;
        // A filled shape that is not light is a bar or a picture, not an empty box.
        var rgb = context.State.FillColor.Rgb;
        bool light = !path.Fill || path.Stroke || (rgb.R + rgb.G + rgb.B) / 3.0 > 217;
        int curves = path.Segments.Count(s => s.Kind == PathSegmentKind.Curve);
        if (curves is >= 4 and <= 8 && path.Segments.All(s => s.Kind != PathSegmentKind.Line))
        {
            Circle(path.Bounds);
            return;
        }
        foreach (var points in Subpaths(path.Segments))
        {
            if (Horizontal.Count + Boxes.Count + Vertical.Count >= MaxItems) return;
            if (points.Count == 2 && path.Stroke) Line(points[0], points[1]);
            else if (points.Count is 4 or 5 && Rectangle(points) is { } box) Shape(box, light);
        }
    }

    private void Line((double X, double Y) a, (double X, double Y) b)
    {
        if (Math.Abs(a.Y - b.Y) <= Tolerance && Math.Abs(a.X - b.X) >= 8) Horizontal.Add(((a.Y + b.Y) / 2, Math.Min(a.X, b.X), Math.Max(a.X, b.X)));
        else if (Math.Abs(a.X - b.X) <= Tolerance && Math.Abs(a.Y - b.Y) >= 8) Vertical.Add(((a.X + b.X) / 2, Math.Min(a.Y, b.Y), Math.Max(a.Y, b.Y)));
    }

    private void Shape(PdfRect box, bool light)
    {
        if (box.Height <= Thin && box.Width >= 8) Horizontal.Add(((box.Bottom + box.Top) / 2, box.Left, box.Right));
        else if (box.Width <= Thin && box.Height >= 8) Vertical.Add(((box.Left + box.Right) / 2, box.Bottom, box.Top));
        else if (light && box.Width >= 5 && box.Height >= 5) Boxes.Add(box);
    }

    private void Circle(PdfRect bounds)
    {
        if (bounds.Width is >= 5 and <= 24 && Math.Abs(bounds.Width - bounds.Height) <= 0.15 * bounds.Width) Circles.Add(bounds);
    }

    private static PdfRect? Rectangle(List<(double X, double Y)> points)
    {
        if (points.Count == 5 && (Math.Abs(points[4].X - points[0].X) > Tolerance || Math.Abs(points[4].Y - points[0].Y) > Tolerance)) return null;
        var box = new PdfRect(points.Take(4).Min(p => p.X), points.Take(4).Min(p => p.Y), points.Take(4).Max(p => p.X), points.Take(4).Max(p => p.Y));
        bool corners = points.Take(4).All(p => (Math.Abs(p.X - box.Left) <= Tolerance || Math.Abs(p.X - box.Right) <= Tolerance)
            && (Math.Abs(p.Y - box.Bottom) <= Tolerance || Math.Abs(p.Y - box.Top) <= Tolerance));
        return corners ? box : null;
    }

    private static List<List<(double X, double Y)>> Subpaths(IReadOnlyList<PathSegment> segments)
    {
        var result = new List<List<(double, double)>>();
        List<(double, double)>? current = null;
        foreach (var s in segments)
        {
            switch (s.Kind)
            {
                case PathSegmentKind.Move:
                    current = [(s.X1, s.Y1)];
                    result.Add(current);
                    break;
                case PathSegmentKind.Line:
                    current?.Add((s.X1, s.Y1));
                    break;
            }
        }
        return result;
    }

    /// <summary>Glyphs in drawing order cut into runs: a new run starts on another line or after a gap wider than half the line height.</summary>
    public List<ScanRun> Runs()
    {
        var runs = new List<ScanRun>();
        var current = new List<ScanGlyph>();
        void Flush()
        {
            if (current.Count == 0) return;
            var box = new PdfRect(current.Min(g => g.Box.Left), current.Min(g => g.Box.Bottom), current.Max(g => g.Box.Right), current.Max(g => g.Box.Top));
            runs.Add(new ScanRun(box, string.Concat(current.Select(g => g.Text)), [.. current]));
            current.Clear();
        }
        foreach (var g in Glyphs)
        {
            if (current.Count > 0)
            {
                var last = current[^1].Box;
                double height = Math.Max(last.Height, g.Box.Height);
                bool sameLine = Math.Abs((last.Bottom + last.Top) / 2 - (g.Box.Bottom + g.Box.Top) / 2) <= 0.4 * height;
                double gap = g.Box.Left - last.Right;
                if (!sameLine || gap > 0.5 * height || gap < -height) Flush();
            }
            current.Add(g);
        }
        Flush();
        return runs;
    }
}
