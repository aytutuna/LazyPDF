namespace LazyPDF.Core;

/// <summary>A straight rule drawn on the page, in display points: <paramref name="Pos"/> is y for a horizontal one and x for a vertical one.</summary>
internal readonly record struct ExportRule(bool Horizontal, double Pos, double From, double To);

/// <summary>Collects the images a page paints and, on request, the straight lines it draws.</summary>
internal sealed class ExportScan(PageGeometry geometry, bool wantRules) : ContentVisitor
{
    private const int MaxImages = 400;
    private const int MaxRules = 20000;

    // Shorter lines are bullets and dashes, thicker ones shading.
    private const double MinRule = 6;
    private const double MaxThickness = 2.5;

    public List<ImageInfo> Images { get; } = [];
    public List<ExportRule> Rules { get; } = [];

    public override void PaintImage(ContentContext context, ImageInfo image)
    {
        if (Images.Count < MaxImages) Images.Add(image);
    }

    public override void PaintPath(ContentContext context, PathInfo path)
    {
        if (!wantRules || Rules.Count >= MaxRules || (!path.Fill && !path.Stroke)) return;
        if (path.Fill && !path.Stroke)
        {
            var box = geometry.ToDisplay(path.Bounds);
            if (Math.Min(box.Width, box.Height) <= MaxThickness && Math.Max(box.Width, box.Height) >= MinRule)
            {
                if (box.Width >= box.Height) Rules.Add(new ExportRule(true, box.Y + box.Height / 2, box.X, box.X + box.Width));
                else Rules.Add(new ExportRule(false, box.X + box.Width / 2, box.Y, box.Y + box.Height));
            }
            return;
        }

        double sx = 0, sy = 0, cx = 0, cy = 0;
        foreach (var s in path.Segments)
        {
            switch (s.Kind)
            {
                case PathSegmentKind.Move:
                    (sx, sy) = (cx, cy) = geometry.ToDisplay(s.X1, s.Y1);
                    break;
                case PathSegmentKind.Line:
                    var (lx, ly) = geometry.ToDisplay(s.X1, s.Y1);
                    Edge(cx, cy, lx, ly);
                    (cx, cy) = (lx, ly);
                    break;
                case PathSegmentKind.Curve:
                    (cx, cy) = geometry.ToDisplay(s.X3, s.Y3);
                    break;
                case PathSegmentKind.Close:
                    Edge(cx, cy, sx, sy);
                    (cx, cy) = (sx, sy);
                    break;
            }
            if (Rules.Count >= MaxRules) return;
        }
    }

    private void Edge(double x1, double y1, double x2, double y2)
    {
        double dx = Math.Abs(x2 - x1), dy = Math.Abs(y2 - y1);
        if (dy <= 0.6 && dx >= MinRule) Rules.Add(new ExportRule(true, (y1 + y2) / 2, Math.Min(x1, x2), Math.Max(x1, x2)));
        else if (dx <= 0.6 && dy >= MinRule) Rules.Add(new ExportRule(false, (x1 + x2) / 2, Math.Min(y1, y2), Math.Max(y1, y2)));
    }
}
