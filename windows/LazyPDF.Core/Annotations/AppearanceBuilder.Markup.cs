namespace LazyPDF.Core;

internal sealed partial class AppearanceBuilder
{
    // Highlights multiply with the page so the text under them stays black (12.5.6.10).
    private AppearanceCanvas Highlight(PdfAnnotation a)
    {
        var c = Canvas(a);
        c.Transparency(a.Opacity, multiply: true);
        if (!c.Color(a.Color ?? Yellow, stroke: false)) return c;
        foreach (var q in a.Quads)
        {
            c.Move(q.X1, q.Y1).Line(q.X2, q.Y2).Line(q.X4, q.Y4).Line(q.X3, q.Y3);
            c.W.Close();
        }
        if (a.Quads.Count > 0) c.W.Fill();
        return c;
    }

    private AppearanceCanvas Underline(PdfAnnotation a, bool strike)
    {
        var c = Canvas(a);
        c.Transparency(a.Opacity, multiply: false);
        if (!c.Color(a.Color ?? Black, stroke: true)) return c;
        foreach (var q in a.Quads)
        {
            double height = Math.Sqrt((q.X1 - q.X3) * (q.X1 - q.X3) + (q.Y1 - q.Y3) * (q.Y1 - q.Y3));
            double width = Math.Clamp(height / 14, 0.75, 2);
            c.Stroke(width, null);
            if (strike)
            {
                c.Move((q.X1 + q.X3) / 2, (q.Y1 + q.Y3) / 2).Line((q.X2 + q.X4) / 2, (q.Y2 + q.Y4) / 2);
            }
            else
            {
                // Lifted by half the width so the stroke stays inside the quad.
                var (ux, uy) = Unit(q.X1 - q.X3, q.Y1 - q.Y3);
                c.Move(q.X3 + ux * width / 2, q.Y3 + uy * width / 2).Line(q.X4 + ux * width / 2, q.Y4 + uy * width / 2);
            }
            c.W.Stroke();
        }
        return c;
    }

    private AppearanceCanvas Squiggly(PdfAnnotation a)
    {
        const double Step = 2, MaxSteps = 20_000;
        var c = Canvas(a);
        c.Transparency(a.Opacity, multiply: false);
        if (!c.Color(a.Color ?? Black, stroke: true)) return c;
        c.Stroke(0.75, null);
        foreach (var q in a.Quads)
        {
            double length = Math.Sqrt((q.X4 - q.X3) * (q.X4 - q.X3) + (q.Y4 - q.Y3) * (q.Y4 - q.Y3));
            var (dx, dy) = Unit(q.X4 - q.X3, q.Y4 - q.Y3);
            var (ux, uy) = Unit(q.X1 - q.X3, q.Y1 - q.Y3);
            int steps = (int)Math.Min(MaxSteps, Math.Ceiling(length / Step));
            for (int i = 0; i <= steps; i++)
            {
                double t = Math.Min(i * Step, length), lift = i % 2 == 0 ? 0.4 : 1.8;
                double x = q.X3 + dx * t + ux * lift, y = q.Y3 + dy * t + uy * lift;
                if (i == 0) c.Move(x, y);
                else c.Line(x, y);
            }
            c.W.Stroke();
        }
        return c;
    }

    internal static (double X, double Y) Unit(double x, double y)
    {
        double length = Math.Sqrt(x * x + y * y);
        return length < 1e-9 ? (0, 1) : (x / length, y / length);
    }
}
