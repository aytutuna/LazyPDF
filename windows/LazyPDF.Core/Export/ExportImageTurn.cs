namespace LazyPDF.Core;

/// <summary>
/// The eight ways a picture can lie on a page, numbered as the Exif orientation tag: 1 upright,
/// 2 mirrored, 3 turned half, 4 mirrored upside down, 5 to 8 the same with a quarter turn.
/// </summary>
internal static class ExportImageTurn
{
    /// <summary>
    /// The orientation of an image whose unit square goes to display space (y down) by
    /// <paramref name="shown"/>. A slant is read as the nearest quarter turn.
    /// </summary>
    public static int Of(PdfMatrix shown)
    {
        if (Math.Abs(shown.B) <= Math.Abs(shown.A))
            return (shown.A < 0, shown.D > 0) switch { (false, false) => 1, (true, false) => 2, (true, true) => 3, _ => 4 };
        return (shown.B > 0, shown.C < 0) switch { (true, true) => 5, (true, false) => 6, (false, false) => 7, _ => 8 };
    }

    public static PdfRgbaImage Apply(PdfRgbaImage image, int orientation)
    {
        if (orientation == 1) return image;
        int w = image.Width, h = image.Height;
        bool swap = orientation >= 5;
        int outWidth = swap ? h : w;
        var rgba = new byte[image.Rgba.Length];
        for (int r = 0; r < h; r++)
        {
            for (int c = 0; c < w; c++)
            {
                var (x, y) = orientation switch
                {
                    2 => (w - 1 - c, r),
                    3 => (w - 1 - c, h - 1 - r),
                    4 => (c, h - 1 - r),
                    5 => (r, c),
                    6 => (h - 1 - r, c),
                    7 => (h - 1 - r, w - 1 - c),
                    _ => (r, w - 1 - c),
                };
                Array.Copy(image.Rgba, (r * w + c) * 4, rgba, (y * outWidth + x) * 4, 4);
            }
        }
        return swap ? new PdfRgbaImage(h, w, rgba) : new PdfRgbaImage(w, h, rgba);
    }
}
