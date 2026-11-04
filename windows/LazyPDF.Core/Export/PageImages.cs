namespace LazyPDF.Core;

/// <summary>Pages as picture files, drawn by the system's renderer.</summary>
public static class PageImages
{
    private const double MaxDpi = 1200;

    /// <summary>The page as a PNG (alpha kept when the renderer gives any); null when the renderer cannot draw it.</summary>
    /// <exception cref="ArgumentOutOfRangeException"><paramref name="dpi"/> is not above 0 and at most 1200.</exception>
    public static byte[]? Png(IPageRenderer renderer, int pageIndex, double dpi)
    {
        CheckDpi(dpi);
        return renderer.Render(pageIndex, dpi) is { } image ? PngWriter.Encode(image) : null;
    }

    /// <summary>The page as a JPEG, any transparency flattened onto white; null when the renderer cannot draw it or the codec cannot encode it.</summary>
    /// <exception cref="ArgumentOutOfRangeException"><paramref name="dpi"/> or <paramref name="quality"/> (1 to 100) is out of range.</exception>
    public static byte[]? Jpeg(IPageRenderer renderer, IImageCodec codec, int pageIndex, double dpi, int quality = 85)
    {
        CheckDpi(dpi);
        if (quality is < 1 or > 100) throw new ArgumentOutOfRangeException(nameof(quality));
        if (renderer.Render(pageIndex, dpi) is not { } image) return null;
        var rgba = (byte[])image.Rgba.Clone();
        for (int i = 0; i + 3 < rgba.Length; i += 4)
        {
            int alpha = rgba[i + 3];
            if (alpha == 255) continue;
            for (int c = 0; c < 3; c++) rgba[i + c] = (byte)((rgba[i + c] * alpha + 255 * (255 - alpha) + 127) / 255);
            rgba[i + 3] = 255;
        }
        return codec.EncodeJpeg(image with { Rgba = rgba }, quality);
    }

    private static void CheckDpi(double dpi)
    {
        if (!(dpi > 0 && dpi <= MaxDpi)) throw new ArgumentOutOfRangeException(nameof(dpi));
    }
}
