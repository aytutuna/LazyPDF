using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>How the pages are coloured on screen. The file is never touched: the tint is applied to the pixels of a tile as it is made.</summary>
public enum PageTint
{
    None,
    Dark,
    Sepia,
}

public static class PageTints
{
    // The paper before its tiles arrive.
    public static Color Paper(PageTint tint) => tint switch
    {
        PageTint.Dark => Color.FromRgb(0x1C, 0x1C, 0x1C),
        PageTint.Sepia => Color.FromRgb(0xF4, 0xEC, 0xD8),
        _ => Colors.White,
    };

    /// <summary>The tile as a frozen bitmap, tinted. Safe on any thread.</summary>
    public static BitmapSource ToBitmap(PdfRgbaImage image, PageTint tint)
    {
        var bgra = ToBgra(image.Rgba, tint);
        var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgr32, null, bgra, image.Width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    /// <summary>B, G, R, 255 for each R, G, B, A of <paramref name="rgba"/>.</summary>
    public static byte[] ToBgra(byte[] rgba, PageTint tint)
    {
        var bgra = new byte[rgba.Length];
        switch (tint)
        {
            case PageTint.Dark:
                Dark(rgba, bgra);
                break;
            case PageTint.Sepia:
                Sepia(rgba, bgra);
                break;
            default:
                for (int i = 0; i < rgba.Length; i += 4)
                {
                    bgra[i] = rgba[i + 2];
                    bgra[i + 1] = rgba[i + 1];
                    bgra[i + 2] = rgba[i];
                    bgra[i + 3] = 255;
                }
                break;
        }
        return bgra;
    }

    // Invert, then turn the hue half way round so colours keep their look: white becomes near black, black near white.
    // The matrix is the hue rotation by 180 degrees, in 1/1024 steps; the result is held between two greys.
    private static void Dark(byte[] rgba, byte[] bgra)
    {
        const int low = 26, high = 232;
        for (int i = 0; i < rgba.Length; i += 4)
        {
            int r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
            int nr = (-588 * r + 1464 * g + 147 * b) >> 10;
            int ng = (436 * r + 440 * g + 147 * b) >> 10;
            int nb = (436 * r + 1464 * g - 876 * b) >> 10;
            bgra[i] = Scale(255 - nb, low, high);
            bgra[i + 1] = Scale(255 - ng, low, high);
            bgra[i + 2] = Scale(255 - nr, low, high);
            bgra[i + 3] = 255;
        }
    }

    private static byte Scale(int v, int low, int high) => (byte)(low + (Math.Clamp(v, 0, 255) * (high - low) + 127) / 255);

    // White paper becomes the paper colour and everything else is darkened in proportion.
    private static void Sepia(byte[] rgba, byte[] bgra)
    {
        for (int i = 0; i < rgba.Length; i += 4)
        {
            bgra[i] = (byte)(rgba[i + 2] * 216 / 255);
            bgra[i + 1] = (byte)(rgba[i + 1] * 236 / 255);
            bgra[i + 2] = (byte)(rgba[i] * 244 / 255);
            bgra[i + 3] = 255;
        }
    }
}
