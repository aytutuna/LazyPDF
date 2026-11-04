namespace LazyPDF.Core;

internal sealed partial class AppearanceBuilder
{
    /// <summary>The size of a line ending for a stroke of <paramref name="width"/>: the arrow head's length, the side of a square.</summary>
    public static double EndingSize(double width) => Math.Max(7, width * 4);

    // dir is the unit vector pointing away from the line, out of the tip.
    private static void DrawEnding(AppearanceCanvas c, PdfAnnotation a, LineEnding ending, (double X, double Y) tip, (double X, double Y) dir)
    {
        if (ending == LineEnding.None || a.Border.Width <= 0) return;
        double size = EndingSize(a.Border.Width);
        bool fill = Paints(a.InteriorColor);
        var perp = (X: -dir.Y, Y: dir.X);
        c.W.Save();
        c.W.Raw("[] 0 d");
        if (fill) c.Color(a.InteriorColor, stroke: false);
        switch (ending)
        {
            case LineEnding.OpenArrow or LineEnding.ClosedArrow or LineEnding.ROpenArrow or LineEnding.RClosedArrow:
            {
                double sign = ending is LineEnding.OpenArrow or LineEnding.ClosedArrow ? 1 : -1;
                var out1 = Rotate(dir.X * sign, dir.Y * sign, Math.PI / 7);
                var out2 = Rotate(dir.X * sign, dir.Y * sign, -Math.PI / 7);
                c.Move(tip.X - out1.X * size, tip.Y - out1.Y * size).Line(tip.X, tip.Y).Line(tip.X - out2.X * size, tip.Y - out2.Y * size);
                bool closed = ending is LineEnding.ClosedArrow or LineEnding.RClosedArrow;
                if (closed) c.W.Close();
                Paint(c, stroke: true, fill: closed && fill);
                break;
            }
            case LineEnding.Butt:
                c.Move(tip.X - perp.X * size / 2, tip.Y - perp.Y * size / 2).Line(tip.X + perp.X * size / 2, tip.Y + perp.Y * size / 2);
                c.W.Stroke();
                break;
            case LineEnding.Slash:
            {
                var slash = Rotate(perp.X, perp.Y, Math.PI / 6);
                c.Move(tip.X - slash.X * size / 2, tip.Y - slash.Y * size / 2).Line(tip.X + slash.X * size / 2, tip.Y + slash.Y * size / 2);
                c.W.Stroke();
                break;
            }
            case LineEnding.Square:
            {
                double h = size * 0.4;
                c.Move(tip.X - dir.X * h - perp.X * h, tip.Y - dir.Y * h - perp.Y * h)
                    .Line(tip.X + dir.X * h - perp.X * h, tip.Y + dir.Y * h - perp.Y * h)
                    .Line(tip.X + dir.X * h + perp.X * h, tip.Y + dir.Y * h + perp.Y * h)
                    .Line(tip.X - dir.X * h + perp.X * h, tip.Y - dir.Y * h + perp.Y * h);
                c.W.Close();
                Paint(c, stroke: true, fill);
                break;
            }
            case LineEnding.Diamond:
            {
                double h = size * 0.5;
                c.Move(tip.X + dir.X * h, tip.Y + dir.Y * h).Line(tip.X + perp.X * h, tip.Y + perp.Y * h)
                    .Line(tip.X - dir.X * h, tip.Y - dir.Y * h).Line(tip.X - perp.X * h, tip.Y - perp.Y * h);
                c.W.Close();
                Paint(c, stroke: true, fill);
                break;
            }
            case LineEnding.Circle:
                c.Ellipse(tip.X - size * 0.4, tip.Y - size * 0.4, tip.X + size * 0.4, tip.Y + size * 0.4);
                Paint(c, stroke: true, fill);
                break;
        }
        c.W.Restore();
    }

    private static (double X, double Y) Rotate(double x, double y, double angle) =>
        (x * Math.Cos(angle) - y * Math.Sin(angle), x * Math.Sin(angle) + y * Math.Cos(angle));
}
