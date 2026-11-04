namespace LazyPDF.Core;

/// <summary>
/// Four corners in page user space: bottom-left, bottom-right, top-right and top-left of a glyph
/// box in the glyph's own frame, so rotated and skewed text keeps its slant.
/// </summary>
public readonly record struct TextQuad(double X0, double Y0, double X1, double Y1, double X2, double Y2, double X3, double Y3)
{
    public PdfRect Bounds => new(
        Math.Min(Math.Min(X0, X1), Math.Min(X2, X3)), Math.Min(Math.Min(Y0, Y1), Math.Min(Y2, Y3)),
        Math.Max(Math.Max(X0, X1), Math.Max(X2, X3)), Math.Max(Math.Max(Y0, Y1), Math.Max(Y2, Y3)));

    public (double X, double Y) Center => ((X0 + X1 + X2 + X3) / 4, (Y0 + Y1 + Y2 + Y3) / 4);

    /// <summary>The eight numbers of a /QuadPoints entry (ISO 32000-1 12.5.6.10): top-left, top-right, bottom-left, bottom-right.</summary>
    public double[] ToQuadPoints() => [X3, Y3, X2, Y2, X0, Y0, X1, Y1];

    public bool Contains(double x, double y)
    {
        double a = Cross(X0, Y0, X1, Y1, x, y), b = Cross(X1, Y1, X2, Y2, x, y);
        double c = Cross(X2, Y2, X3, Y3, x, y), d = Cross(X3, Y3, X0, Y0, x, y);
        return (a >= 0 && b >= 0 && c >= 0 && d >= 0) || (a <= 0 && b <= 0 && c <= 0 && d <= 0);
    }

    /// <summary>Zero inside, else the distance to the nearest edge.</summary>
    public double DistanceTo(double x, double y)
    {
        if (Contains(x, y)) return 0;
        return Math.Min(Math.Min(Edge(X0, Y0, X1, Y1, x, y), Edge(X1, Y1, X2, Y2, x, y)),
            Math.Min(Edge(X2, Y2, X3, Y3, x, y), Edge(X3, Y3, X0, Y0, x, y)));
    }

    private static double Cross(double ax, double ay, double bx, double by, double px, double py) =>
        (bx - ax) * (py - ay) - (by - ay) * (px - ax);

    private static double Edge(double ax, double ay, double bx, double by, double px, double py)
    {
        double dx = bx - ax, dy = by - ay, length = dx * dx + dy * dy;
        double t = length == 0 ? 0 : Math.Clamp(((px - ax) * dx + (py - ay) * dy) / length, 0, 1);
        return Math.Sqrt(Math.Pow(px - (ax + t * dx), 2) + Math.Pow(py - (ay + t * dy), 2));
    }
}

/// <summary>Grows a quad around quads in the frame of the first one added.</summary>
internal struct QuadBox
{
    private double _ux, _uy, _vx, _vy, _umin, _umax, _vmin, _vmax;
    private bool _started;

    public readonly bool IsEmpty => !_started;

    public void Add(in TextQuad q)
    {
        if (!_started)
        {
            double ux = q.X1 - q.X0, uy = q.Y1 - q.Y0, length = Math.Sqrt(ux * ux + uy * uy);
            if (length < 1e-9)
            {
                // A zero-width glyph: take the frame from its height.
                double hx = q.X3 - q.X0, hy = q.Y3 - q.Y0, height = Math.Sqrt(hx * hx + hy * hy);
                (ux, uy, length) = height < 1e-9 ? (1, 0, 1) : (hy, -hx, height);
            }
            _ux = ux / length;
            _uy = uy / length;
            _vx = -_uy;
            _vy = _ux;
            if ((q.X3 - q.X0) * _vx + (q.Y3 - q.Y0) * _vy < 0)
            {
                _vx = -_vx;
                _vy = -_vy;
            }
            (_umin, _vmin) = (double.MaxValue, double.MaxValue);
            (_umax, _vmax) = (double.MinValue, double.MinValue);
            _started = true;
        }
        Include(q.X0, q.Y0);
        Include(q.X1, q.Y1);
        Include(q.X2, q.Y2);
        Include(q.X3, q.Y3);
    }

    private void Include(double x, double y)
    {
        double u = x * _ux + y * _uy, v = x * _vx + y * _vy;
        _umin = Math.Min(_umin, u);
        _umax = Math.Max(_umax, u);
        _vmin = Math.Min(_vmin, v);
        _vmax = Math.Max(_vmax, v);
    }

    public readonly TextQuad ToQuad()
    {
        var (ux, uy, vx, vy) = (_ux, _uy, _vx, _vy);
        (double X, double Y) P(double u, double v) => (u * ux + v * vx, u * uy + v * vy);
        var (a, b, c, d) = (P(_umin, _vmin), P(_umax, _vmin), P(_umax, _vmax), P(_umin, _vmax));
        return new TextQuad(a.X, a.Y, b.X, b.Y, c.X, c.Y, d.X, d.Y);
    }
}
