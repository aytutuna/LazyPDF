namespace LazyPDF.Core;

internal sealed partial class AppearanceBuilder
{
    /// <summary>Opacity, colours, width and dash of the shape; says whether it strokes and whether it fills.</summary>
    private static (bool Stroke, bool Fill) Setup(AppearanceCanvas c, PdfAnnotation a, bool fillable)
    {
        c.Transparency(a.Opacity, multiply: false);
        bool stroke = a.Border.Width > 0 && c.Color(a.Color ?? Red, stroke: true);
        bool fill = fillable && Paints(a.InteriorColor) && c.Color(a.InteriorColor, stroke: false);
        if (stroke)
        {
            c.Stroke(a.Border.Width, a.Border.Style == BorderStyle.Dashed ? a.Border.Dash : null);
            c.W.Raw("1 j");
        }
        return (stroke, fill);
    }

    private static void Paint(AppearanceCanvas c, bool stroke, bool fill)
    {
        if (stroke && fill) c.W.FillAndStroke();
        else if (fill) c.W.Fill();
        else if (stroke) c.W.Stroke();
        else c.W.EndPath();
    }

    private AppearanceCanvas Shape(PdfAnnotation a, bool ellipse)
    {
        var c = Canvas(a);
        var (stroke, fill) = Setup(c, a, fillable: true);
        var rd = a.RectDifference;
        bool cloud = a.Cloud > 0;
        double half = cloud ? 0 : a.Border.Width / 2;
        double left = a.Rect.Left + (rd.Count == 4 ? rd[0] : 0) + half, bottom = a.Rect.Bottom + (rd.Count == 4 ? rd[1] : 0) + half;
        double right = a.Rect.Right - (rd.Count == 4 ? rd[2] : 0) - half, top = a.Rect.Top - (rd.Count == 4 ? rd[3] : 0) - half;
        if (right <= left || top <= bottom) return c;
        if (cloud)
        {
            double spacing = CloudBorder.Spacing(a.Cloud);
            CloudBorder.Draw(c, ellipse
                ? CloudBorder.EllipsePoints(left, bottom, right, top, spacing)
                : CloudBorder.RectPoints(left, bottom, right, top, spacing));
        }
        else if (ellipse) c.Ellipse(left, bottom, right, top);
        else c.W.Rect(c.X(left), c.Y(bottom), right - left, top - bottom);
        Paint(c, stroke, fill);
        return c;
    }

    private AppearanceCanvas Polygon(PdfAnnotation a)
    {
        var c = Canvas(a);
        var (stroke, fill) = Setup(c, a, fillable: true);
        var points = Points(a.Vertices);
        if (points.Count < 2) return c;
        if (a.Cloud > 0 && points.Count >= 3) CloudBorder.Draw(c, CloudBorder.Resample(points, CloudBorder.Spacing(a.Cloud)));
        else c.Polyline(points, close: true);
        Paint(c, stroke, fill);
        return c;
    }

    private AppearanceCanvas PolyLine(PdfAnnotation a)
    {
        var c = Canvas(a);
        var (stroke, fill) = Setup(c, a, fillable: false);
        var points = Points(a.Vertices);
        if (points.Count < 2) return c;
        if (stroke)
        {
            c.Polyline(points, close: false);
            c.W.Stroke();
        }
        var first = points[0];
        var second = points[1];
        var last = points[^1];
        var before = points[^2];
        DrawEnding(c, a, a.StartEnding, first, Unit(first.X - second.X, first.Y - second.Y));
        DrawEnding(c, a, a.EndEnding, last, Unit(last.X - before.X, last.Y - before.Y));
        return c;
    }

    private AppearanceCanvas Line(PdfAnnotation a)
    {
        var c = Canvas(a);
        var (stroke, _) = Setup(c, a, fillable: false);
        if (a.Line.Count < 4) return c;
        var p = (X: a.Line[0], Y: a.Line[1]);
        var q = (X: a.Line[2], Y: a.Line[3]);
        if (stroke)
        {
            c.Move(p.X, p.Y).Line(q.X, q.Y);
            c.W.Stroke();
        }
        DrawEnding(c, a, a.StartEnding, p, Unit(p.X - q.X, p.Y - q.Y));
        DrawEnding(c, a, a.EndEnding, q, Unit(q.X - p.X, q.Y - p.Y));
        return c;
    }

    private AppearanceCanvas Ink(PdfAnnotation a)
    {
        var c = Canvas(a);
        var (stroke, _) = Setup(c, a, fillable: false);
        if (!stroke) return c;
        c.W.Raw("1 J");
        foreach (var path in a.InkList)
        {
            var points = Points(path);
            if (points.Count == 0) continue;
            Smooth(c, points);
            c.W.Stroke();
        }
        return c;
    }

    // Quadratic curves between the midpoints of the samples, so a hand-drawn stroke has no corners.
    private static void Smooth(AppearanceCanvas c, List<(double X, double Y)> p)
    {
        c.Move(p[0].X, p[0].Y);
        if (p.Count == 1)
        {
            c.Line(p[0].X, p[0].Y);
            return;
        }
        if (p.Count == 2)
        {
            c.Line(p[1].X, p[1].Y);
            return;
        }
        var from = p[0];
        for (int i = 1; i < p.Count - 1; i++)
        {
            var mid = ((p[i].X + p[i + 1].X) / 2, (p[i].Y + p[i + 1].Y) / 2);
            c.Curve(from.X + 2.0 / 3 * (p[i].X - from.X), from.Y + 2.0 / 3 * (p[i].Y - from.Y),
                mid.Item1 + 2.0 / 3 * (p[i].X - mid.Item1), mid.Item2 + 2.0 / 3 * (p[i].Y - mid.Item2), mid.Item1, mid.Item2);
            from = mid;
        }
        c.Line(p[^1].X, p[^1].Y);
    }

    internal static List<(double X, double Y)> Points(IReadOnlyList<double> numbers)
    {
        var points = new List<(double X, double Y)>(numbers.Count / 2);
        for (int i = 0; i + 1 < numbers.Count; i += 2) points.Add((numbers[i], numbers[i + 1]));
        return points;
    }

    private AppearanceCanvas Link(PdfAnnotation a)
    {
        var c = Canvas(a);
        if (a.Border.Width <= 0 || !Paints(a.Color)) return c;
        c.Color(a.Color, stroke: true);
        c.Stroke(a.Border.Width, a.Border.Style == BorderStyle.Dashed ? a.Border.Dash : null);
        double half = a.Border.Width / 2;
        c.W.Rect(half, half, a.Rect.Width - a.Border.Width, a.Rect.Height - a.Border.Width);
        c.W.Stroke();
        return c;
    }
}
