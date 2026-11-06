using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>
/// The picture codecs Core leaves to the system, on WIC through WPF's decoders: JPEG, PNG, TIFF (every
/// frame), BMP, GIF and HEIC where Windows has the extension, and JPEG encoding. WPF finds the decoder
/// by the bytes, not the name.
/// </summary>
public sealed class WicImageCodec : IImageCodec
{
    private const int MaxFrames = 2000;

    public PdfRgbaImage? Decode(byte[] data, string codec) =>
        codec is "DCTDecode" or "JPXDecode" ? DecodeFile(data) is { Count: > 0 } frames ? frames[0] : null : null;

    public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file)
    {
        try
        {
            using var stream = new MemoryStream(file);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            return [.. decoder.Frames.Take(MaxFrames).Select(ToRgba)];
        }
        catch (Exception e) when (e is NotSupportedException or FileFormatException or InvalidOperationException or ArgumentException or IOException or OutOfMemoryException)
        {
            return null;
        }
    }

    public byte[] EncodeJpeg(PdfRgbaImage image, int quality)
    {
        var encoder = new JpegBitmapEncoder { QualityLevel = Math.Clamp(quality, 1, 100) };
        encoder.Frames.Add(BitmapFrame.Create(OverWhite(image)));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    private static PdfRgbaImage ToRgba(BitmapSource source)
    {
        var converted = source.Format == PixelFormats.Bgra32 ? source : new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        int width = converted.PixelWidth, height = converted.PixelHeight;
        // The size is the codestream's own, whatever the dictionary says, and width * height * 4 wraps an int.
        if ((long)width * height > PdfImageSamples.MaxPixels) throw new NotSupportedException();
        var pixels = new byte[width * height * 4];
        converted.CopyPixels(pixels, width * 4, 0);
        for (int i = 0; i < pixels.Length; i += 4) (pixels[i], pixels[i + 2]) = (pixels[i + 2], pixels[i]);
        return new PdfRgbaImage(width, height, pixels);
    }

    // JPEG has no alpha: what is see-through goes onto white, as it would on paper.
    private static BitmapSource OverWhite(PdfRgbaImage image)
    {
        var bgr = new byte[image.Width * image.Height * 3];
        for (int i = 0, o = 0; i < image.Rgba.Length; i += 4, o += 3)
        {
            int alpha = image.Rgba[i + 3];
            for (int c = 0; c < 3; c++) bgr[o + c] = (byte)((image.Rgba[i + 2 - c] * alpha + 255 * (255 - alpha) + 127) / 255);
        }
        var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgr24, null, bgr, image.Width * 3);
        bitmap.Freeze();
        return bitmap;
    }
}
