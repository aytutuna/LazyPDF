using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.App.Tools.Export;
using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>
/// The picture codecs Core leaves to the system, on WIC through WPF's decoders: JPEG, PNG, TIFF (every
/// frame), BMP, GIF and HEIC where Windows has the extension, and JPEG, TIFF and BMP encoding. WPF finds the decoder
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
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.None);
            // A frame is decoded when it is read, so one too big to hold is passed over by its header size alone.
            return [.. decoder.Frames.Take(MaxFrames).Where(f => (long)f.PixelWidth * f.PixelHeight <= PdfImageSamples.MaxPixels).Select(ToRgba)];
        }
        catch (Exception e) when (e is NotSupportedException or FileFormatException or InvalidOperationException or ArgumentException or IOException or OutOfMemoryException or OverflowException)
        {
            return null;
        }
    }

    public byte[] EncodeJpeg(PdfRgbaImage image, int quality)
    {
        return Encode(new JpegBitmapEncoder { QualityLevel = Math.Clamp(quality, 1, 100) }, image);
    }

    public byte[] EncodeTiff(PdfRgbaImage image, int dpi = 96) => Encode(image, PictureFormat.Tiff, PictureColour.Colour, 0, dpi);

    public byte[] EncodeBmp(PdfRgbaImage image, int dpi = 96) => Encode(image, PictureFormat.Bmp, PictureColour.Colour, 0, dpi);

    public byte[] Encode(PdfRgbaImage image, PictureFormat format, PictureColour colour, int quality, int dpi = 96)
    {
        BitmapEncoder encoder = format switch
        {
            PictureFormat.Jpeg => new JpegBitmapEncoder { QualityLevel = Math.Clamp(quality, 1, 100) },
            PictureFormat.Tiff => new TiffBitmapEncoder { Compression = colour == PictureColour.BlackWhite ? TiffCompressOption.Ccitt4 : TiffCompressOption.Lzw },
            PictureFormat.Bmp => new BmpBitmapEncoder(),
            _ => new PngBitmapEncoder(),
        };
        return Encode(encoder, ToSource(image, colour, dpi));
    }

    private static byte[] Encode(BitmapEncoder encoder, PdfRgbaImage image) => Encode(encoder, OverWhite(image, 96));

    private static byte[] Encode(BitmapEncoder encoder, BitmapSource source)
    {
        encoder.Frames.Add(BitmapFrame.Create(source));
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

    private static BitmapSource ToSource(PdfRgbaImage image, PictureColour colour, int dpi)
    {
        var bgr = OverWhite(image, dpi);
        if (colour == PictureColour.Colour) return bgr;
        int width = image.Width, height = image.Height, stride = width * 3;
        var pixels = new byte[stride * height];
        bgr.CopyPixels(pixels, stride, 0);
        var gray = new byte[width * height];
        for (int i = 0, o = 0; o < gray.Length; i += 3, o++) gray[o] = (byte)(0.299 * pixels[i + 2] + 0.587 * pixels[i + 1] + 0.114 * pixels[i] + 0.5);
        BitmapSource result;
        if (colour == PictureColour.Grayscale)
        {
            result = BitmapSource.Create(width, height, dpi, dpi, PixelFormats.Gray8, null, gray, width);
        }
        else
        {
            int row = (width + 7) / 8;
            var bits = new byte[row * height];
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++)
                    if (gray[y * width + x] >= 128) bits[y * row + x / 8] |= (byte)(0x80 >> (x % 8));
            result = BitmapSource.Create(width, height, dpi, dpi, PixelFormats.BlackWhite, null, bits, row);
        }
        result.Freeze();
        return result;
    }

    // These formats have no alpha: what is see-through goes onto white, as it would on paper.
    private static BitmapSource OverWhite(PdfRgbaImage image, int dpi)
    {
        var bgr = new byte[image.Width * image.Height * 3];
        for (int i = 0, o = 0; i < image.Rgba.Length; i += 4, o += 3)
        {
            int alpha = image.Rgba[i + 3];
            for (int c = 0; c < 3; c++) bgr[o + c] = (byte)((image.Rgba[i + 2 - c] * alpha + 255 * (255 - alpha) + 127) / 255);
        }
        var bitmap = BitmapSource.Create(image.Width, image.Height, dpi, dpi, PixelFormats.Bgr24, null, bgr, image.Width * 3);
        bitmap.Freeze();
        return bitmap;
    }
}
