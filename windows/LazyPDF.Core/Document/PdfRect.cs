namespace LazyPDF.Core;

/// <summary>A rectangle in PDF user space (origin bottom-left, y up), never upside down: <see cref="Left"/> is at most <see cref="Right"/> and <see cref="Bottom"/> at most <see cref="Top"/>.</summary>
public readonly record struct PdfRect
{
    public PdfRect(double x1, double y1, double x2, double y2)
    {
        Left = Math.Min(x1, x2);
        Bottom = Math.Min(y1, y2);
        Right = Math.Max(x1, x2);
        Top = Math.Max(y1, y2);
    }

    public double Left { get; }
    public double Bottom { get; }
    public double Right { get; }
    public double Top { get; }

    public double Width => Right - Left;
    public double Height => Top - Bottom;
    public bool IsEmpty => Width <= 0 || Height <= 0;

    /// <summary>The part both rectangles cover; empty (and at <see cref="Left"/>, <see cref="Bottom"/> of this one) when they miss.</summary>
    public PdfRect Intersect(PdfRect other)
    {
        double left = Math.Max(Left, other.Left), bottom = Math.Max(Bottom, other.Bottom);
        double right = Math.Min(Right, other.Right), top = Math.Min(Top, other.Top);
        return right > left && top > bottom ? new PdfRect(left, bottom, right, top) : new PdfRect(Left, Bottom, Left, Bottom);
    }

    /// <summary>[left bottom right top] as a PDF array.</summary>
    public PdfArray ToArray() =>
        new([new PdfNumber(Left), new PdfNumber(Bottom), new PdfNumber(Right), new PdfNumber(Top)]);
}
