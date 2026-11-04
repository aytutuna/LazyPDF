using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>Core's pixels as something WPF draws.</summary>
public static class Pixels
{
    /// <summary>A frozen bitmap (so any thread may hand it to the window) of <paramref name="image"/>.</summary>
    public static BitmapSource ToBitmap(PdfRgbaImage image, double dpi = 96)
    {
        var bgra = new byte[image.Rgba.Length];
        for (int i = 0; i < bgra.Length; i += 4)
        {
            bgra[i] = image.Rgba[i + 2];
            bgra[i + 1] = image.Rgba[i + 1];
            bgra[i + 2] = image.Rgba[i];
            bgra[i + 3] = image.Rgba[i + 3];
        }
        var bitmap = BitmapSource.Create(image.Width, image.Height, dpi, dpi, PixelFormats.Bgra32, null, bgra, image.Width * 4);
        bitmap.Freeze();
        return bitmap;
    }
}
