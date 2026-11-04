using System.Text;

namespace LazyPDF.Core;

/// <summary>Where a painted or clipping path meets the marks, and what is left of it outside them.</summary>
internal static class RedactionPaths
{
    private const int CurveSteps = 8;
    private const int MaxPieces = 4096;
    private const long MaxClipWork = 1_000_000;

    public static string Polygons(IEnumerable<IReadOnlyList<(double X, double Y)>> polygons)
    {
        var path = new StringBuilder();
        foreach (var polygon in polygons) Polygon(path, polygon);
        return path.ToString();
    }

    public static void Polygon(StringBuilder path, IReadOnlyList<(double X, double Y)> points)
    {
        for (int i = 0; i < points.Count; i++) path.Append(new PdfNumber(points[i].X).Text).Append(' ').Append(new PdfNumber(points[i].Y).Text).Append(i == 0 ? " m\n" : " l\n");
        path.Append("h\n");
    }

    private static List<List<(double X, double Y)>> Flatten(PathInfo path, out List<bool> closed)
    {
        var result = new List<List<(double X, double Y)>>();
        closed = [];
        List<(double X, double Y)>? current = null;
        (double X, double Y) last = default;
        foreach (var s in path.Segments)
        {
            switch (s.Kind)
            {
                case PathSegmentKind.Move:
                    current = [(s.X1, s.Y1)];
                    result.Add(current);
                    closed.Add(false);
                    last = (s.X1, s.Y1);
                    break;
                case PathSegmentKind.Line when current is not null:
                    current.Add(last = (s.X1, s.Y1));
                    break;
                case PathSegmentKind.Curve when current is not null:
                    var start = last;
                    for (int i = 1; i <= CurveSteps; i++)
                    {
                        double t = (double)i / CurveSteps, u = 1 - t;
                        current.Add((u * u * u * start.X + 3 * u * u * t * s.X1 + 3 * u * t * t * s.X2 + t * t * t * s.X3,
                                     u * u * u * start.Y + 3 * u * u * t * s.Y1 + 3 * u * t * t * s.Y2 + t * t * t * s.Y3));
                    }
                    last = (s.X3, s.Y3);
                    break;
                case PathSegmentKind.Close when current is not null:
                    closed[^1] = true;
                    last = current[0];
                    break;
            }
        }
        return result;
    }

    /// <summary>A path that only clips counts as filled: the region it opens is what is tested.</summary>
    public static bool Meets(PathInfo path, MarkArea area)
    {
        var ink = path.InkBounds;
        if (ink.Right < area.Bounds.Left || ink.Left > area.Bounds.Right || ink.Top < area.Bounds.Bottom || ink.Bottom > area.Bounds.Top) return false;
        bool fill = path.Fill || !path.Stroke;
        var subpaths = Flatten(path, out var closed);
        double half = Math.Max(0, (path.InkBounds.Width - path.Bounds.Width) / 2);
        for (int s = 0; s < subpaths.Count; s++)
        {
            var points = subpaths[s];
            bool wrap = fill || closed[s];
            for (int i = 0; i < points.Count; i++)
            {
                if (i + 1 == points.Count && !wrap) break;
                double reach = Geometry.Distance(points[i], points[(i + 1) % points.Count], area);
                if (fill && reach == 0) return true;
                if (path.Stroke && reach <= half) return true;
            }
        }
        if (!fill) return false;
        var inside = area.Points.Append((X: area.Points.Average(p => p.X), Y: area.Points.Average(p => p.Y)));
        return inside.Any(p => Geometry.Inside(subpaths, path.EvenOdd, p.X, p.Y));
    }

    public static PdfRect? AxisRectangle(PathInfo path)
    {
        var points = new List<(double X, double Y)>();
        foreach (var s in path.Segments)
        {
            if (s.Kind == PathSegmentKind.Move && points.Count == 0) points.Add((s.X1, s.Y1));
            else if (s.Kind == PathSegmentKind.Line) points.Add((s.X1, s.Y1));
            else if (s.Kind != PathSegmentKind.Close) return null;
        }
        if (points.Count == 5 && Near(points[0], points[4])) points.RemoveAt(4);
        if (points.Count != 4) return null;
        bool horizontalFirst = Same(points[0].Y, points[1].Y) && Same(points[1].X, points[2].X) && Same(points[2].Y, points[3].Y) && Same(points[3].X, points[0].X);
        bool verticalFirst = Same(points[0].X, points[1].X) && Same(points[1].Y, points[2].Y) && Same(points[2].X, points[3].X) && Same(points[3].Y, points[0].Y);
        if (!horizontalFirst && !verticalFirst) return null;
        return new PdfRect(points.Min(p => p.X), points.Min(p => p.Y), points.Max(p => p.X), points.Max(p => p.Y));
    }

    /// <summary>The rectangle with the boxes of the marks taken out, as polygons.</summary>
    public static List<List<(double X, double Y)>> Around(PdfRect rect, IEnumerable<MarkArea> hit)
    {
        var pieces = new List<PdfRect> { rect };
        foreach (var area in hit) pieces = [.. pieces.SelectMany(p => Subtract(p, area.Bounds))];
        return [.. pieces.Select(Corners)];
    }

    /// <summary>
    /// The outline of a clipping path with the boxes of the marks taken out: each subpath, flattened,
    /// cut to the rectangles around the marks. Empty when nothing is left or the work would be too
    /// much; the caller then clips to nothing, which only hides more.
    /// </summary>
    public static List<List<(double X, double Y)>> Outside(PathInfo path, IReadOnlyList<MarkArea> hit)
    {
        var pieces = new List<PdfRect> { path.Bounds };
        foreach (var area in hit)
        {
            pieces = [.. pieces.SelectMany(p => Subtract(p, area.Bounds))];
            if (pieces.Count > MaxPieces) return [];
        }
        var subpaths = Flatten(path, out _);
        var result = new List<List<(double X, double Y)>>();
        if ((long)pieces.Count * subpaths.Count > MaxClipWork) return result;
        foreach (var piece in pieces)
        {
            var box = new MarkArea(Corners(piece));
            if (!box.IsUsable) continue;
            foreach (var subpath in subpaths)
            {
                if (subpath.Count < 3) continue;
                var cut = Geometry.Clip(subpath, box);
                if (cut.Count >= 3 && Geometry.Area(cut) > 1e-9) result.Add(cut);
            }
        }
        return result;
    }

    private static List<(double X, double Y)> Corners(PdfRect r) => [(r.Left, r.Bottom), (r.Right, r.Bottom), (r.Right, r.Top), (r.Left, r.Top)];

    private static bool Same(double a, double b) => Math.Abs(a - b) < 1e-6;

    private static bool Near((double X, double Y) a, (double X, double Y) b) => Same(a.X, b.X) && Same(a.Y, b.Y);

    // A band to the left and right over the full height and the strips above and below between them.
    private static IEnumerable<PdfRect> Subtract(PdfRect r, PdfRect cut)
    {
        if (cut.Right <= r.Left || cut.Left >= r.Right || cut.Top <= r.Bottom || cut.Bottom >= r.Top)
        {
            yield return r;
            yield break;
        }
        double left = Math.Max(cut.Left, r.Left), right = Math.Min(cut.Right, r.Right);
        if (cut.Left > r.Left) yield return new PdfRect(r.Left, r.Bottom, cut.Left, r.Top);
        if (cut.Right < r.Right) yield return new PdfRect(cut.Right, r.Bottom, r.Right, r.Top);
        if (cut.Top < r.Top) yield return new PdfRect(left, cut.Top, right, r.Top);
        if (cut.Bottom > r.Bottom) yield return new PdfRect(left, r.Bottom, right, cut.Bottom);
    }
}
