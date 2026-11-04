namespace LazyPDF.Core;

/// <summary>A rectangle in display points: origin top-left, y down.</summary>
public readonly record struct DisplayRect(double X, double Y, double Width, double Height);

/// <summary>
/// Converts between a page's user space (points, origin bottom-left) and the display points the
/// app uses (origin top-left, y down) for the page as shown: the crop box, /Rotate (clockwise)
/// and /UserUnit applied (ISO 32000-1 7.7.3.3, 14.11.2). Nothing else in the engine does this.
/// </summary>
public sealed class PageGeometry
{
    private readonly double _a, _b, _c, _d, _e, _f;
    private readonly double _ia, _ib, _ic, _id, _ie, _if;

    public PageGeometry(PdfPage page) : this(page.CropBox, page.Rotate, page.UserUnit) { }

    /// <param name="box">The visible region in user space.</param>
    /// <param name="rotate">Clockwise degrees, a multiple of 90.</param>
    /// <param name="userUnit">User space units per point; 1 unless the page says otherwise.</param>
    public PageGeometry(PdfRect box, int rotate, double userUnit = 1)
    {
        double u = userUnit > 0 ? userUnit : 1;
        Rotation = ((rotate % 360) + 360) % 360 / 90 * 90;
        bool turned = Rotation is 90 or 270;
        Width = (turned ? box.Height : box.Width) * u;
        Height = (turned ? box.Width : box.Height) * u;
        // display = (a x + c y + e, b x + d y + f)
        (_a, _b, _c, _d, _e, _f) = Rotation switch
        {
            90 => (0d, u, u, 0d, -box.Bottom * u, -box.Left * u),
            180 => (-u, 0d, 0d, u, box.Right * u, -box.Bottom * u),
            270 => (0d, -u, -u, 0d, box.Top * u, box.Right * u),
            _ => (u, 0d, 0d, -u, -box.Left * u, box.Top * u),
        };
        double det = _a * _d - _b * _c;
        _ia = _d / det;
        _ib = -_b / det;
        _ic = -_c / det;
        _id = _a / det;
        _ie = (_c * _f - _d * _e) / det;
        _if = (_b * _e - _a * _f) / det;
    }

    /// <summary>The page as shown, in display points.</summary>
    public double Width { get; }
    public double Height { get; }

    /// <summary>The rotation applied: 0, 90, 180 or 270.</summary>
    public int Rotation { get; }

    /// <summary>The matrix [a b c d e f] taking user space to display points (x' = ax + cy + e, y' = bx + dy + f).</summary>
    public (double A, double B, double C, double D, double E, double F) Matrix => (_a, _b, _c, _d, _e, _f);

    public (double X, double Y) ToDisplay(double x, double y) => (_a * x + _c * y + _e, _b * x + _d * y + _f);

    public (double X, double Y) ToUser(double x, double y) => (_ia * x + _ic * y + _ie, _ib * x + _id * y + _if);

    /// <summary>The display rectangle that covers a user-space one.</summary>
    public DisplayRect ToDisplay(PdfRect rect)
    {
        var (x1, y1) = ToDisplay(rect.Left, rect.Bottom);
        var (x2, y2) = ToDisplay(rect.Right, rect.Top);
        return new DisplayRect(Math.Min(x1, x2), Math.Min(y1, y2), Math.Abs(x2 - x1), Math.Abs(y2 - y1));
    }

    /// <summary>The user-space rectangle that a display one covers.</summary>
    public PdfRect ToUser(DisplayRect rect)
    {
        var (x1, y1) = ToUser(rect.X, rect.Y);
        var (x2, y2) = ToUser(rect.X + rect.Width, rect.Y + rect.Height);
        return new PdfRect(x1, y1, x2, y2);
    }
}
