namespace LazyPDF.Core;

/// <summary>
/// A transformation matrix [a b c d e f] (ISO 32000-1 8.3.4): x' = ax + cy + e, y' = bx + dy + f.
/// <see cref="Multiply"/> applies this matrix first and the other second, the order the spec writes
/// its products in.
/// </summary>
public readonly record struct PdfMatrix(double A, double B, double C, double D, double E, double F)
{
    public static readonly PdfMatrix Identity = new(1, 0, 0, 1, 0, 0);

    public static PdfMatrix Translate(double x, double y) => new(1, 0, 0, 1, x, y);

    public static PdfMatrix Scale(double x, double y) => new(x, 0, 0, y, 0, 0);

    public double Determinant => A * D - B * C;

    /// <summary>The square root of the area scale, a fair single number for line widths and font sizes.</summary>
    public double ScaleFactor => Math.Sqrt(Math.Abs(Determinant));

    public PdfMatrix Multiply(PdfMatrix m) => new(
        A * m.A + B * m.C, A * m.B + B * m.D,
        C * m.A + D * m.C, C * m.B + D * m.D,
        E * m.A + F * m.C + m.E, E * m.B + F * m.D + m.F);

    public (double X, double Y) Transform(double x, double y) => (A * x + C * y + E, B * x + D * y + F);

    /// <summary>The box that covers the four transformed corners.</summary>
    public PdfRect Transform(PdfRect r)
    {
        var (x1, y1) = Transform(r.Left, r.Bottom);
        var (x2, y2) = Transform(r.Right, r.Bottom);
        var (x3, y3) = Transform(r.Right, r.Top);
        var (x4, y4) = Transform(r.Left, r.Top);
        return new PdfRect(Math.Min(Math.Min(x1, x2), Math.Min(x3, x4)), Math.Min(Math.Min(y1, y2), Math.Min(y3, y4)),
                           Math.Max(Math.Max(x1, x2), Math.Max(x3, x4)), Math.Max(Math.Max(y1, y2), Math.Max(y3, y4)));
    }

    /// <summary>The inverse, or null when the matrix flattens the plane.</summary>
    public PdfMatrix? Invert()
    {
        double det = Determinant;
        if (det == 0 || !double.IsFinite(det)) return null;
        return new PdfMatrix(D / det, -B / det, -C / det, A / det, (C * F - D * E) / det, (B * E - A * F) / det);
    }

    /// <summary>The matrix an array of six numbers stands for; null for anything else.</summary>
    public static PdfMatrix? FromArray(PdfArray? array, Func<PdfObject?, PdfObject?> resolve)
    {
        if (array is not { Items.Count: >= 6 }) return null;
        Span<double> n = stackalloc double[6];
        for (int i = 0; i < 6; i++)
        {
            if (resolve(array.Items[i]) is not PdfNumber { Value: var v } || !double.IsFinite(v)) return null;
            n[i] = v;
        }
        return new PdfMatrix(n[0], n[1], n[2], n[3], n[4], n[5]);
    }
}
