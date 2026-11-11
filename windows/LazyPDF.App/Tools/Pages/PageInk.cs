using LazyPDF.Core;

namespace LazyPDF.App.Tools.Pages;

/// <summary>Where the ink is on a page rendered over white, for trimming margins and spotting blank pages.</summary>
internal static class PageInk
{
    /// <summary>About 50 dark pixels on A4 at 72 dpi: a page number or a speck passes as blank, one line of words does not.</summary>
    public const double BlankShare = 0.0001;

    /// <summary>The pixel box (right and bottom exclusive) holding the ink, or null. A border row or column needs two ink pixels, or one with ink in the next one inward, so a lone speck does not widen it but a thin stroke stays.</summary>
    public static (int Left, int Top, int Right, int Bottom)? Bounds(PdfRgbaImage image, int white = 245)
    {
        int w = image.Width, h = image.Height;
        byte[] px = image.Rgba;

        int Row(int y)
        {
            int n = 0;
            for (int x = 0; x < w; x++)
                if (Ink(px, (y * w + x) * 4, white) && ++n == 2) break;
            return n;
        }

        int top = 0;
        while (top < h && !Edge(Row, top, 1, h, Math.Min(2, w))) top++;
        if (top == h) return null;
        int bottom = h;
        while (!Edge(Row, bottom - 1, -1, h, Math.Min(2, w))) bottom--;

        int Column(int x)
        {
            int n = 0;
            for (int y = top; y < bottom; y++)
                if (Ink(px, (y * w + x) * 4, white) && ++n == 2) break;
            return n;
        }

        int need = Math.Min(2, bottom - top);
        int left = 0;
        while (left < w && !Edge(Column, left, 1, w, need)) left++;
        // Ink on different columns of different rows leaves no column of its own: keep the full width.
        if (left == w) return (0, top, w, bottom);
        int right = w;
        while (!Edge(Column, right - 1, -1, w, need)) right--;
        return (left, top, right, bottom);
    }

    private static bool Edge(Func<int, int> count, int i, int step, int length, int need)
    {
        int n = count(i);
        if (n >= need) return n > 0;
        int next = i + step;
        return n == 1 && next >= 0 && next < length && count(next) > 0;
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
