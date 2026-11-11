using LazyPDF.Core;

namespace LazyPDF.App.Tools.Pages;

/// <summary>Where the ink is on a page rendered over white, for trimming margins and spotting blank pages.</summary>
internal static class PageInk
{
    /// <summary>About 50 dark pixels on A4 at 72 dpi: a page number or a speck passes as blank, one line of words does not.</summary>
    public const double BlankShare = 0.0001;

    /// <summary>The pixel box (right and bottom exclusive) holding the ink, or null. A border row or column needs two ink pixels, so one speck does not widen it.</summary>
    public static (int Left, int Top, int Right, int Bottom)? Bounds(PdfRgbaImage image, int white = 245)
    {
        int w = image.Width, h = image.Height;
        byte[] px = image.Rgba;

        int Row(int y, int from, int to)
        {
            int n = 0;
            for (int x = from; x < to; x++)
                if (Ink(px, (y * w + x) * 4, white) && ++n == 2) break;
            return n;
        }

        int Column(int x, int from, int to)
        {
            int n = 0;
            for (int y = from; y < to; y++)
                if (Ink(px, (y * w + x) * 4, white) && ++n == 2) break;
            return n;
        }

        int top = 0;
        while (top < h && Row(top, 0, w) < 2) top++;
        if (top == h) return null;
        int bottom = h;
        while (Row(bottom - 1, 0, w) < 2) bottom--;
        int left = 0;
        while (Column(left, top, bottom) < 2) left++;
        int right = w;
        while (Column(right - 1, top, bottom) < 2) right--;
        return (left, top, right, bottom);
    }

    public static double DarkShare(PdfRgbaImage image, int dark = 160)
    {
        byte[] px = image.Rgba;
        int count = image.Width * image.Height;
        if (count == 0) return 0;
        long n = 0;
        for (int i = 0; i < count * 4; i += 4)
            if (Ink(px, i, dark)) n++;
        return (double)n / count;
    }

    public static bool IsBlank(PdfRgbaImage image) => DarkShare(image) <= BlankShare;

    private static bool Ink(byte[] px, int i, int white) =>
        px[i + 3] > 8 && Math.Min(px[i], Math.Min(px[i + 1], px[i + 2])) < white;
}
