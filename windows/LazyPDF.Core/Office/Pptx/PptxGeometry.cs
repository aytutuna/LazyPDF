namespace LazyPDF.Core.Office;

/// <summary>A plane transform: x' = A x + C y + E, y' = B x + D y + F.</summary>
internal readonly record struct Affine(double A, double B, double C, double D, double E, double F)
{
    public static readonly Affine Identity = new(1, 0, 0, 1, 0, 0);

    public static Affine Translate(double x, double y) => new(1, 0, 0, 1, x, y);

    public static Affine Scale(double x, double y) => new(x, 0, 0, y, 0, 0);

    /// <summary>A turn clockwise on a page whose y runs down. Right angles are exact.</summary>
    public static Affine Rotate(double degrees)
    {
        degrees %= 360;
        if (degrees < 0) degrees += 360;
        double cos, sin;
        switch (degrees)
        {
            case 0: cos = 1; sin = 0; break;
            case 90: cos = 0; sin = 1; break;
            case 180: cos = -1; sin = 0; break;
            case 270: cos = 0; sin = -1; break;
            default:
                cos = Math.Cos(degrees * Math.PI / 180);
                sin = Math.Sin(degrees * Math.PI / 180);
                break;
        }
        return new Affine(cos, sin, -sin, cos, 0, 0);
    }

    /// <summary>The transform that applies <paramref name="first"/> and then this one.</summary>
    public Affine Multiply(Affine first) => new(
        A * first.A + C * first.B, B * first.A + D * first.B,
        A * first.C + C * first.D, B * first.C + D * first.D,
        A * first.E + C * first.F + E, B * first.E + D * first.F + F);

    public static double Length(double x, double y) => Math.Sqrt(x * x + y * y);

    public (double X, double Y) Apply(double x, double y) => (A * x + C * y + E, B * x + D * y + F);
}

/// <summary>
/// The preset shapes of DrawingML that slides use most, as outlines in a box of width w and height h with the corner at 0, 0,
/// following the formulas of the presetShapeDefinitions of ECMA-376. Adjust values are in hundredths of a percent as the file
/// states them.
/// </summary>
internal static class PptxGeometry
{
    private const double Kappa = 0.5522847498307936;

    private static readonly HashSet<string> Presets =
    [
        "rect", "roundRect", "ellipse", "triangle", "rtTriangle", "diamond", "parallelogram", "trapezoid", "pentagon", "hexagon", "octagon",
        "chevron", "homePlate", "star5", "rightArrow", "leftArrow", "upArrow", "downArrow", "line", "straightConnector1",
    ];

    public static bool Supports(string preset) => Presets.Contains(preset);

    public static bool IsLine(string preset) => preset is "line" or "straightConnector1";

    public static List<PathCommand> Build(string preset, double w, double h, IReadOnlyDictionary<string, double> adjust)
    {
        double Adj(string name, double fallback, double max = 100_000) => Math.Clamp(adjust.TryGetValue(name, out double v) ? v : fallback, 0, max);
        double ss = Math.Min(w, h);
        switch (preset)
        {
            case "line":
            case "straightConnector1":
                return [PathCommand.Move(0, 0), PathCommand.Line(w, h)];
            case "roundRect":
            {
                double r = ss * Adj("adj", 16667, 50_000) / 100_000, k = r * Kappa;
                return
                [
                    PathCommand.Move(r, 0), PathCommand.Line(w - r, 0), PathCommand.Curve(w - r + k, 0, w, r - k, w, r),
                    PathCommand.Line(w, h - r), PathCommand.Curve(w, h - r + k, w - r + k, h, w - r, h),
                    PathCommand.Line(r, h), PathCommand.Curve(r - k, h, 0, h - r + k, 0, h - r),
                    PathCommand.Line(0, r), PathCommand.Curve(0, r - k, r - k, 0, r, 0), PathCommand.Close(),
                ];
            }
            case "ellipse":
                return Ellipse(w / 2, h / 2, w / 2, h / 2);
            case "triangle":
                return Polygon((0, h), (w * Adj("adj", 50_000) / 100_000, 0), (w, h));
            case "rtTriangle":
                return Polygon((0, h), (0, 0), (w, h));
            case "diamond":
                return Polygon((0, h / 2), (w / 2, 0), (w, h / 2), (w / 2, h));
            case "parallelogram":
            {
                double x = ss * Adj("adj", 25_000, ss > 0 ? 100_000 * w / ss : 0) / 100_000;
                return Polygon((0, h), (x, 0), (w, 0), (w - x, h));
            }
            case "trapezoid":
            {
                double x = ss * Adj("adj", 25_000, ss > 0 ? 50_000 * w / ss : 0) / 100_000;
                return Polygon((0, h), (x, 0), (w - x, 0), (w, h));
            }
            case "pentagon":
                return Star(5, w, h, 1, 1.05146, 1.10557);
            case "star5":
                return Star(5, w, h, Adj("adj", 19098, 50_000) / 50_000, 1.05146, 1.10557);
            case "hexagon":
            {
                double x = ss * Adj("adj", 25_000, ss > 0 ? 50_000 * w / ss : 0) / 100_000;
                return Polygon((0, h / 2), (x, 0), (w - x, 0), (w, h / 2), (w - x, h), (x, h));
            }
            case "octagon":
            {
                double x = ss * Adj("adj", 29289, 50_000) / 100_000;
                return Polygon((0, x), (x, 0), (w - x, 0), (w, x), (w, h - x), (w - x, h), (x, h), (0, h - x));
            }
            case "chevron":
            {
                double x = ss * Adj("adj", 50_000, ss > 0 ? 100_000 * w / ss : 0) / 100_000;
                return Polygon((0, 0), (w - x, 0), (w, h / 2), (w - x, h), (0, h), (x, h / 2));
            }
            case "homePlate":
            {
                double x = w - ss * Adj("adj", 50_000, ss > 0 ? 100_000 * w / ss : 0) / 100_000;
                return Polygon((0, 0), (x, 0), (w, h / 2), (x, h), (0, h));
            }
            case "rightArrow":
                return Arrow(w, h, Adj("adj1", 50_000), adjust, false, false);
            case "leftArrow":
                return Arrow(w, h, Adj("adj1", 50_000), adjust, true, false);
            case "downArrow":
                return Arrow(h, w, Adj("adj1", 50_000), adjust, false, true);
            case "upArrow":
                return Arrow(h, w, Adj("adj1", 50_000), adjust, true, true);
            default:
                return Polygon((0, 0), (w, 0), (w, h), (0, h));
        }
    }

    private static List<PathCommand> Polygon(params (double X, double Y)[] points)
    {
        var list = new List<PathCommand>(points.Length + 1);
        for (int i = 0; i < points.Length; i++) list.Add(i == 0 ? PathCommand.Move(points[i].X, points[i].Y) : PathCommand.Line(points[i].X, points[i].Y));
        list.Add(PathCommand.Close());
        return list;
    }

    private static List<PathCommand> Ellipse(double cx, double cy, double rx, double ry)
    {
        double kx = rx * Kappa, ky = ry * Kappa;
        return
        [
            PathCommand.Move(cx - rx, cy),
            PathCommand.Curve(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry),
            PathCommand.Curve(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy),
            PathCommand.Curve(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry),
            PathCommand.Curve(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy),
            PathCommand.Close(),
        ];
    }

    // The outline of an n-pointed star: the points on the ellipse of the box (stretched by hf and vf as the definitions do so
    // that the points touch its edges) and the inner corners at the fraction `inner` of that radius, half a step between.
    private static List<PathCommand> Star(int points, double w, double h, double inner, double hf, double vf)
    {
        double rx = w / 2 * hf, ry = h / 2 * vf, cx = w / 2, cy = h / 2 * vf;
        var list = new List<PathCommand>();
        int count = inner < 1 ? points * 2 : points;
        for (int i = 0; i < count; i++)
        {
            double angle = (-90 + 360.0 * i / count) * Math.PI / 180, scale = inner < 1 && i % 2 == 1 ? inner : 1;
            double x = cx + rx * scale * Math.Cos(angle), y = cy + ry * scale * Math.Sin(angle);
            list.Add(i == 0 ? PathCommand.Move(x, y) : PathCommand.Line(x, y));
        }
        list.Add(PathCommand.Close());
        return list;
    }

    // An arrow pointing right in a box of length x thickness, mirrored for left, and turned into the other axis for up and down.
    private static List<PathCommand> Arrow(double length, double thickness, double shaft, IReadOnlyDictionary<string, double> adjust, bool reverse, bool vertical)
    {
        double ss = Math.Min(length, thickness);
        double maxHead = ss > 0 ? 100_000 * length / ss : 0;
        double head = ss * Math.Clamp(adjust.TryGetValue("adj2", out double v) ? v : 50_000, 0, maxHead) / 100_000;
        double half = thickness * shaft / 200_000, mid = thickness / 2, x = length - head;
        var points = new (double, double)[]
        {
            (0, mid - half), (x, mid - half), (x, 0), (length, mid), (x, thickness), (x, mid + half), (0, mid + half),
        };
        for (int i = 0; i < points.Length; i++)
        {
            var (px, py) = points[i];
            if (reverse) px = length - px;
            points[i] = vertical ? (py, px) : (px, py);
        }
        return Polygon(points);
    }
}
