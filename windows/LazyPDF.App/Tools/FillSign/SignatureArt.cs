using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Ink;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.FillSign;

/// <summary>Turns a typed name, ink or a picture into the transparent image that is placed on a page.</summary>
internal static class SignatureArt
{
    // Drawn and typed signatures are made at this many pixels per DIP so that they stay sharp when placed larger.
    private const int Scale = 3;
    private const int MaxPictureWidth = 900;
    private const int Margin = 4;

    public static PdfRgbaImage? Typed(string text, string family, Color? ink = null)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var line = new FormattedText(text.Trim(), CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface(family), 40, new SolidColorBrush(ink ?? Colors.Black), 1.0);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new ScaleTransform(Scale, Scale));
            dc.DrawText(line, new Point(Margin, Margin));
        }
        return Trim(Render(visual, line.WidthIncludingTrailingWhitespace + 2 * Margin, line.Height + 2 * Margin));
    }

    public static PdfRgbaImage? Drawn(StrokeCollection strokes, Color? ink = null)
    {
        if (strokes.Count == 0) return null;
        var bounds = strokes.GetBounds();
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new ScaleTransform(Scale, Scale));
            dc.PushTransform(new TranslateTransform(Margin - bounds.X, Margin - bounds.Y));
            foreach (var stroke in strokes)
            {
                var copy = stroke.Clone();
                copy.DrawingAttributes.Color = ink ?? Colors.Black;
                copy.Draw(dc);
            }
        }
        return Trim(Render(visual, bounds.Width + 2 * Margin, bounds.Height + 2 * Margin));
    }

    /// <summary>A picture of a signature on paper: the paper becomes see-through, the ink stays.</summary>
    public static PdfRgbaImage? FromFile(byte[] file)
    {
        if (new WicImageCodec().DecodeFile(file) is not { Count: > 0 } frames) return null;
        return Trim(PaperToClear(Shrink(Upright(frames[0], Orientation(file)))));
    }

    /// <summary>A camera JPEG turned upright and saved without its orientation tag; any other file as it is.</summary>
    public static byte[] UprightFile(byte[] file)
    {
        if (file.Length < 2 || file[0] != 0xFF || file[1] != 0xD8) return file;
        int orientation = Orientation(file);
        if (orientation is < 2 or > 8) return file;
        var codec = new WicImageCodec();
        if (codec.DecodeFile(file) is not { Count: > 0 } frames) return file;
        return codec.EncodeJpeg(Upright(frames[0], orientation), 92);
    }

    /// <summary>The picture turned a quarter clockwise.</summary>
    public static PdfRgbaImage Turn(PdfRgbaImage image) => Read(new TransformedBitmap(ToBitmap(image), new RotateTransform(90)));

    public static byte[] ToPng(PdfRgbaImage image)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(ToBitmap(image)));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    public static BitmapSource ToBitmap(PdfRgbaImage image)
    {
        var bgra = new byte[image.Rgba.Length];
        for (int i = 0; i < bgra.Length; i += 4)
        {
            bgra[i] = image.Rgba[i + 2];
            bgra[i + 1] = image.Rgba[i + 1];
            bgra[i + 2] = image.Rgba[i];
            bgra[i + 3] = image.Rgba[i + 3];
        }
        var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgra32, null, bgra, image.Width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    private static PdfRgbaImage Render(DrawingVisual visual, double width, double height)
    {
        var target = new RenderTargetBitmap(Math.Max(1, (int)Math.Ceiling(width * Scale)), Math.Max(1, (int)Math.Ceiling(height * Scale)), 96, 96, PixelFormats.Pbgra32);
        target.Render(visual);
        return Read(target);
    }

    private static PdfRgbaImage Read(BitmapSource source)
    {
        var converted = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        int w = converted.PixelWidth, h = converted.PixelHeight;
        var pixels = new byte[w * h * 4];
        converted.CopyPixels(pixels, w * 4, 0);
        for (int i = 0; i < pixels.Length; i += 4) (pixels[i], pixels[i + 2]) = (pixels[i + 2], pixels[i]);
        return new PdfRgbaImage(w, h, pixels);
    }

    // The orientation a camera stores in the file (EXIF 1 to 8), which the pixels do not show.
    private static int Orientation(byte[] file)
    {
        try
        {
            using var stream = new MemoryStream(file);
            var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None).Frames[0];
            return (frame.Metadata as BitmapMetadata)?.GetQuery("System.Photo.Orientation") is ushort value ? value : 1;
        }
        catch (Exception e) when (e is NotSupportedException or FileFormatException or InvalidOperationException or ArgumentException or IOException or COMException)
        {
            return 1;
        }
    }

    private static PdfRgbaImage Upright(PdfRgbaImage image, int orientation)
    {
        if (orientation is < 2 or > 8) return image;
        int turn = orientation switch { 3 or 4 => 180, 5 or 6 => 90, 7 or 8 => 270, _ => 0 };
        BitmapSource picture = ToBitmap(image);
        if (turn != 0) picture = new TransformedBitmap(picture, new RotateTransform(turn));
        if (orientation is 2 or 4 or 5 or 7) picture = new TransformedBitmap(picture, new ScaleTransform(-1, 1));
        return Read(picture);
    }

    internal static PdfRgbaImage Shrink(PdfRgbaImage image, int maxWidth = MaxPictureWidth)
    {
        if (image.Width <= maxWidth) return image;
        double factor = (double)maxWidth / image.Width;
        return Read(new TransformedBitmap(ToBitmap(image), new ScaleTransform(factor, factor)));
    }

    // A photo has no alpha and a grey cast over the paper, so the cut-off sits a little below white and
    // fades in over the next stretch of darkness to keep the edge of the pen soft.
    internal static PdfRgbaImage PaperToClear(PdfRgbaImage image)
    {
        var pixels = (byte[])image.Rgba.Clone();
        for (int i = 0; i < pixels.Length; i += 4)
        {
            int luma = (pixels[i] * 299 + pixels[i + 1] * 587 + pixels[i + 2] * 114) / 1000;
            pixels[i + 3] = (byte)(pixels[i + 3] * Math.Clamp((235 - luma) * 255 / 100, 0, 255) / 255);
        }
        return image with { Rgba = pixels };
    }

    /// <summary>The picture cut to the part that is not see-through, with a thin border; a picture with nothing in it comes back as it is.</summary>
    internal static PdfRgbaImage Trim(PdfRgbaImage image)
    {
        int left = image.Width, top = image.Height, right = -1, bottom = -1;
        for (int y = 0; y < image.Height; y++)
        {
            for (int x = 0; x < image.Width; x++)
            {
                if (image.Rgba[(y * image.Width + x) * 4 + 3] < 8) continue;
                left = Math.Min(left, x);
                right = Math.Max(right, x);
                top = Math.Min(top, y);
                bottom = Math.Max(bottom, y);
            }
        }
        if (right < 0) return image;
        left = Math.Max(0, left - Margin);
        top = Math.Max(0, top - Margin);
        right = Math.Min(image.Width - 1, right + Margin);
        bottom = Math.Min(image.Height - 1, bottom + Margin);
        int w = right - left + 1, h = bottom - top + 1;
        var pixels = new byte[w * h * 4];
        for (int y = 0; y < h; y++) Array.Copy(image.Rgba, ((top + y) * image.Width + left) * 4, pixels, y * w * 4, w * 4);
        return new PdfRgbaImage(w, h, pixels);
    }
}
