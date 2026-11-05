using System.Windows;

namespace LazyPDF.App.Tools.Measure;

public enum MeasureKind
{
    Distance,
    Perimeter,
    Area,
}

/// <summary>A finished measurement: points of one page in page space, not yet written to the file.</summary>
public sealed record MeasureItem(MeasureKind Kind, int Page, IReadOnlyList<Point> Points)
{
    public string Title => Kind switch
    {
        MeasureKind.Distance => Loc.T("Distance"),
        MeasureKind.Perimeter => Loc.T("Perimeter"),
        _ => Loc.T("Area"),
    };

    public string Value(MeasureScale scale) => Kind == MeasureKind.Area
        ? scale.Area(MeasureShape.Area(Points))
        : scale.Length(MeasureShape.Length(Points, Kind == MeasureKind.Perimeter));

    public Point Middle => Kind == MeasureKind.Distance
        ? new Point((Points[0].X + Points[^1].X) / 2, (Points[0].Y + Points[^1].Y) / 2)
        : new Point(Points.Average(p => p.X), Points.Average(p => p.Y));
}

public static class MeasureShape
{
    public static double Length(IReadOnlyList<Point> points, bool closed)
    {
        double sum = 0;
        for (int i = 1; i < points.Count; i++) sum += (points[i] - points[i - 1]).Length;
        if (closed && points.Count > 2) sum += (points[0] - points[^1]).Length;
        return sum;
    }

    public static double Area(IReadOnlyList<Point> points)
    {
        double twice = 0;
        for (int i = 0; i < points.Count; i++)
        {
            var a = points[i];
            var b = points[(i + 1) % points.Count];
            twice += a.X * b.Y - b.X * a.Y;
        }
        return Math.Abs(twice) / 2;
    }

    public static Point? Nearest(IEnumerable<Point> candidates, Point at, double radius)
    {
        Point? best = null;
        double near = radius;
        foreach (var c in candidates)
        {
            double d = (c - at).Length;
            if (d > near) continue;
            near = d;
            best = c;
        }
        return best;
    }

    /// <summary>The place at the same distance from <paramref name="from"/> along the nearest multiple of 45 degrees.</summary>
    public static Point Straighten(Point from, Point to)
    {
        var d = to - from;
        double step = Math.PI / 4;
        double angle = Math.Round(Math.Atan2(d.Y, d.X) / step) * step;
        return new Point(from.X + d.Length * Math.Cos(angle), from.Y + d.Length * Math.Sin(angle));
    }
}
