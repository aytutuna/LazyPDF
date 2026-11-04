namespace LazyPDF.Core;

/// <summary>The scalloped border of /BE /S /C (ISO 32000-1 12.5.4): a closed path replaced by a chain of outward arcs.</summary>
internal static class CloudBorder
{
    private const int MaxPoints = 20_000;

    public static double Spacing(int intensity) => 6 + 4 * Math.Clamp(intensity, 1, 2);

    /// <summary>How far an arc bulges out of the path it replaces.</summary>
    public static double Bulge(int intensity) => Spacing(intensity) * 0.4;

    /// <summary>The corners with the edges cut into pieces about <paramref name="spacing"/> long, so that every corner stays a join between two arcs.</summary>
    public static List<(double X, double Y)> Resample(IReadOnlyList<(double X, double Y)> corners, double spacing)
    {
        double perimeter = 0;
        for (int i = 0; i < corners.Count; i++) perimeter += Distance(corners[i], corners[(i + 1) % corners.Count]);
        spacing = Math.Max(spacing, perimeter / MaxPoints);
        var points = new List<(double X, double Y)>();
        for (int i = 0; i < corners.Count; i++)
        {
            var p = corners[i];
            var q = corners[(i + 1) % corners.Count];
            int pieces = Math.Max(1, (int)Math.Ceiling(Distance(p, q) / spacing));
            for (int k = 0; k < pieces; k++)
            {
                double t = (double)k / pieces;
                points.Add((p.X + (q.X - p.X) * t, p.Y + (q.Y - p.Y) * t));
            }
        }
        return points;
    }

    /// <summary>Points equally far apart along the ellipse's own length, at most <paramref name="spacing"/> apart.</summary>
    public static List<(double X, double Y)> EllipsePoints(double left, double bottom, double right, double top, double spacing)
    {
        const int Steps = 720;
        double cx = (left + right) / 2, cy = (bottom + top) / 2, rx = (right - left) / 2, ry = (top - bottom) / 2;
        var dense = new (double X, double Y)[Steps + 1];
        var length = new double[Steps + 1];
        for (int i = 0; i <= Steps; i++)
        {
            double angle = 2 * Math.PI * i / Steps;
            dense[i] = (cx + rx * Math.Cos(angle), cy + ry * Math.Sin(angle));
            if (i > 0) length[i] = length[i - 1] + Distance(dense[i - 1], dense[i]);
        }
        int count = (int)Math.Clamp(Math.Ceiling(length[Steps] / spacing), 6, MaxPoints);
        var points = new List<(double X, double Y)>(count);
        for (int k = 0, at = 0; k < count; k++)
        {
            double target = length[Steps] * k / count;
            while (at < Steps - 1 && length[at + 1] < target) at++;
            double span = length[at + 1] - length[at];
            double t = span > 0 ? (target - length[at]) / span : 0;
            points.Add((dense[at].X + (dense[at + 1].X - dense[at].X) * t, dense[at].Y + (dense[at + 1].Y - dense[at].Y) * t));
        }
        return points;
    }

    public static List<(double X, double Y)> RectPoints(double left, double bottom, double right, double top, double spacing) =>
        Resample([(left, bottom), (right, bottom), (right, top), (left, top)], spacing);

    /// <summary>Adds the closed scalloped path of the points, which must run once around the shape.</summary>
    public static void Draw(AppearanceCanvas canvas, IReadOnlyList<(double X, double Y)> points)
    {
        if (points.Count < 3) return;
        double area = 0;
        for (int i = 0; i < points.Count; i++)
        {
            var (x1, y1) = points[i];
            var (x2, y2) = points[(i + 1) % points.Count];
            area += x1 * y2 - x2 * y1;
        }
        // Outward is to the right of a counter-clockwise walk, to the left of a clockwise one.
        double side = area >= 0 ? 1 : -1;
        canvas.Move(points[0].X, points[0].Y);
        for (int i = 0; i < points.Count; i++)
        {
            var p = points[i];
            var q = points[(i + 1) % points.Count];
            double length = Distance(p, q);
            if (length < 1e-6) continue;
            // A cubic whose handles stand 4/3 of the height out peaks at that height.
            double h = length * 0.4 * 4 / 3;
            double nx = side * (q.Y - p.Y) / length * h, ny = -side * (q.X - p.X) / length * h;
            canvas.Curve(p.X + nx, p.Y + ny, q.X + nx, q.Y + ny, q.X, q.Y);
        }
        canvas.W.Close();
    }

    private static double Distance((double X, double Y) p, (double X, double Y) q) =>
        Math.Sqrt((q.X - p.X) * (q.X - p.X) + (q.Y - p.Y) * (q.Y - p.Y));
}
