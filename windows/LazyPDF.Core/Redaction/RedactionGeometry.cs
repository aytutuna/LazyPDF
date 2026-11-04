namespace LazyPDF.Core;

/// <summary>A marked area as a convex polygon in page user space, counter-clockwise.</summary>
internal sealed class MarkArea
{
    public MarkArea(IReadOnlyList<(double X, double Y)> corners)
    {
        double cx = corners.Average(p => p.X), cy = corners.Average(p => p.Y);
        Points = [.. corners.OrderBy(p => Math.Atan2(p.Y - cy, p.X - cx))];
        Bounds = new PdfRect(Points.Min(p => p.X), Points.Min(p => p.Y), Points.Max(p => p.X), Points.Max(p => p.Y));
        Area = Geometry.Area(Points);
    }

    public (double X, double Y)[] Points { get; }
    public PdfRect Bounds { get; }
    public double Area { get; }
    public bool IsUsable => Area > 1e-6;

    public static MarkArea Of(TextQuad q) => new([(q.X0, q.Y0), (q.X1, q.Y1), (q.X2, q.Y2), (q.X3, q.Y3)]);
}

internal static class Geometry
{
    // A glyph box is the font's ascent to descent, wider than the ink and overlapping the lines above
    // and below in tight text. Only its middle is tested, so a mark drawn round a word does not take
    // its neighbours, while one that crosses a glyph at all does.
    private const double Core = 0.7;

    public static double Area(IReadOnlyList<(double X, double Y)> p)
    {
        double sum = 0;
        for (int i = 0; i < p.Count; i++)
        {
            var (a, b) = (p[i], p[(i + 1) % p.Count]);
            sum += a.X * b.Y - b.X * a.Y;
        }
        return Math.Abs(sum) / 2;
    }

    public static bool Contains(MarkArea area, double x, double y)
    {
        var p = area.Points;
        for (int i = 0; i < p.Length; i++)
        {
            var (a, b) = (p[i], p[(i + 1) % p.Length]);
            if ((b.X - a.X) * (y - a.Y) - (b.Y - a.Y) * (x - a.X) < -1e-9) return false;
        }
        return true;
    }

    /// <summary>The part of a polygon inside the area (Sutherland-Hodgman); empty when they miss.</summary>
    public static List<(double X, double Y)> Clip(IReadOnlyList<(double X, double Y)> subject, MarkArea area)
    {
        var output = subject.ToList();
        var clip = area.Points;
        for (int i = 0; i < clip.Length && output.Count > 0; i++)
        {
            var (a, b) = (clip[i], clip[(i + 1) % clip.Length]);
            var input = output;
            output = [];
            for (int j = 0; j < input.Count; j++)
            {
                var (cur, prev) = (input[j], input[(j + input.Count - 1) % input.Count]);
                double sc = Side(a, b, cur), sp = Side(a, b, prev);
                if (sc >= 0)
                {
                    if (sp < 0) output.Add(Cut(prev, cur, sp, sc));
                    output.Add(cur);
                }
                else if (sp >= 0)
                {
                    output.Add(Cut(prev, cur, sp, sc));
                }
            }
        }
        return output;
    }

    private static double Side((double X, double Y) a, (double X, double Y) b, (double X, double Y) p) =>
        (b.X - a.X) * (p.Y - a.Y) - (b.Y - a.Y) * (p.X - a.X);

    private static (double X, double Y) Cut((double X, double Y) p, (double X, double Y) q, double sp, double sq)
    {
        double t = sp / (sp - sq);
        return (p.X + t * (q.X - p.X), p.Y + t * (q.Y - p.Y));
    }

    /// <summary>The polygon and the area share some surface (a polygon with none is tested at its centre).</summary>
    public static bool Overlaps(IReadOnlyList<(double X, double Y)> polygon, MarkArea area)
    {
        if (polygon.Count == 0) return false;
        if (Area(polygon) > 1e-9) return Area(Clip(polygon, area)) > 1e-7;
        return Contains(area, polygon.Average(p => p.X), polygon.Average(p => p.Y));
    }

    public static bool GlyphMeets(IReadOnlyList<(double X, double Y)> box, MarkArea area)
    {
        double cx = box.Average(p => p.X), cy = box.Average(p => p.Y);
        return Overlaps([.. box.Select(p => (cx + Core * (p.X - cx), cy + Core * (p.Y - cy)))], area);
    }

    public static List<(double X, double Y)> Corners(PdfMatrix m, double left, double bottom, double right, double top) =>
        [m.Transform(left, bottom), m.Transform(right, bottom), m.Transform(right, top), m.Transform(left, top)];

    public static List<(double X, double Y)> Corners(TextQuad q) => [(q.X0, q.Y0), (q.X1, q.Y1), (q.X2, q.Y2), (q.X3, q.Y3)];

    public static bool Meets(PdfRect rect, MarkArea area) =>
        !rect.IsEmpty && Overlaps([(rect.Left, rect.Bottom), (rect.Right, rect.Bottom), (rect.Right, rect.Top), (rect.Left, rect.Top)], area);

    /// <summary>Distance between a segment and the area, zero when they touch.</summary>
    public static double Distance((double X, double Y) a, (double X, double Y) b, MarkArea area)
    {
        if (Contains(area, a.X, a.Y) || Contains(area, b.X, b.Y)) return 0;
        var p = area.Points;
        double best = double.MaxValue;
        for (int i = 0; i < p.Length; i++)
        {
            var (c, d) = (p[i], p[(i + 1) % p.Length]);
            if (Crosses(a, b, c, d)) return 0;
            best = Math.Min(best, Math.Min(Math.Min(ToSegment(a, c, d), ToSegment(b, c, d)), Math.Min(ToSegment(c, a, b), ToSegment(d, a, b))));
        }
        return best;
    }

    private static bool Crosses((double X, double Y) a, (double X, double Y) b, (double X, double Y) c, (double X, double Y) d)
    {
        double d1 = Side(a, b, c), d2 = Side(a, b, d), d3 = Side(c, d, a), d4 = Side(c, d, b);
        return d1 * d2 < 0 && d3 * d4 < 0;
    }

    private static double ToSegment((double X, double Y) p, (double X, double Y) a, (double X, double Y) b)
    {
        double dx = b.X - a.X, dy = b.Y - a.Y, length = dx * dx + dy * dy;
        double t = length == 0 ? 0 : Math.Clamp(((p.X - a.X) * dx + (p.Y - a.Y) * dy) / length, 0, 1);
        return Math.Sqrt(Math.Pow(p.X - (a.X + t * dx), 2) + Math.Pow(p.Y - (a.Y + t * dy), 2));
    }

    /// <summary>Whether the fill of a path (all its subpaths, closed) has the point inside.</summary>
    public static bool Inside(IReadOnlyList<List<(double X, double Y)>> subpaths, bool evenOdd, double x, double y)
    {
        int winding = 0, crossings = 0;
        foreach (var path in subpaths)
        {
            for (int i = 0; i < path.Count; i++)
            {
                var (a, b) = (path[i], path[(i + 1) % path.Count]);
                if ((a.Y <= y) == (b.Y <= y)) continue;
                double at = a.X + (y - a.Y) / (b.Y - a.Y) * (b.X - a.X);
                if (at <= x) continue;
                crossings++;
                winding += b.Y > a.Y ? 1 : -1;
            }
        }
        return evenOdd ? crossings % 2 == 1 : winding != 0;
    }
}
