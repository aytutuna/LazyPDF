namespace LazyPDF.Core;

internal enum ImageFamily { Gray, Rgb, Cmyk, Indexed, Lab, Spot, Unknown }

// What an image's colour space is made of, and plain pixel arithmetic over decoded samples.
internal static class ImageKit
{
    public static (ImageFamily Family, int Components) Describe(PdfDocument document, PdfObject? colorSpace)
    {
        switch (document.Resolve(colorSpace))
        {
            case PdfName name:
                return name.Value switch
                {
                    "DeviceGray" or "G" or "CalGray" => (ImageFamily.Gray, 1),
                    "DeviceRGB" or "RGB" or "CalRGB" => (ImageFamily.Rgb, 3),
                    "DeviceCMYK" or "CMYK" => (ImageFamily.Cmyk, 4),
                    _ => (ImageFamily.Unknown, 0),
                };
            case PdfArray { Items.Count: > 0 } array when document.Resolve(array.Items[0]) is PdfName kind:
                switch (kind.Value)
                {
                    case "CalGray": return (ImageFamily.Gray, 1);
                    case "CalRGB": return (ImageFamily.Rgb, 3);
                    case "Lab": return (ImageFamily.Lab, 3);
                    case "Indexed" or "I": return (ImageFamily.Indexed, 1);
                    case "Separation": return (ImageFamily.Spot, 1);
                    case "DeviceN":
                        return document.Resolve(array.Items.Count > 1 ? array.Items[1] : null) is PdfArray names ? (ImageFamily.Spot, names.Items.Count) : (ImageFamily.Unknown, 0);
                    case "ICCBased":
                        long n = array.Items.Count > 1 && document.Resolve(array.Items[1]) is PdfStream profile ? document.Integer(profile.Dictionary, "N") ?? 0 : 0;
                        return n switch { 1 => (ImageFamily.Gray, 1), 3 => (ImageFamily.Rgb, 3), 4 => (ImageFamily.Cmyk, 4), _ => (ImageFamily.Unknown, 0) };
                    case "DeviceGray" or "DeviceRGB" or "DeviceCMYK":
                        return Describe(document, kind);
                }
                break;
        }
        return (ImageFamily.Unknown, 0);
    }

    /// <summary>The samples of an image at 8 bits each, rows packed; 16-bit samples keep their high byte, fewer bits are scaled to the full range.</summary>
    public static byte[] Unpack(byte[] data, int width, int height, int components, int bpc)
    {
        int perRow = width * components;
        var result = new byte[(long)perRow * height];
        int rowBytes = (perRow * bpc + 7) / 8;
        for (int y = 0; y < height; y++)
        {
            long from = (long)y * rowBytes;
            if (from >= data.Length) break;
            int available = (int)Math.Min(rowBytes, data.Length - from);
            var row = data.AsSpan((int)from, available);
            var to = result.AsSpan(y * perRow, perRow);
            switch (bpc)
            {
                case 8:
                    row[..Math.Min(perRow, row.Length)].CopyTo(to);
                    break;
                case 16:
                    for (int i = 0; i < perRow && 2 * i < row.Length; i++) to[i] = row[2 * i];
                    break;
                default:
                    int max = (1 << bpc) - 1;
                    for (int i = 0; i < perRow; i++)
                    {
                        int bit = i * bpc;
                        if (bit / 8 >= row.Length) break;
                        to[i] = (byte)((row[bit / 8] >> (8 - bpc - bit % 8) & max) * 255 / max);
                    }
                    break;
            }
        }
        return result;
    }

    /// <summary>Shrinks 8-bit samples by averaging the source pixels each new pixel covers.</summary>
    public static byte[] Shrink(byte[] source, int width, int height, int components, int newWidth, int newHeight)
    {
        var result = new byte[(long)newWidth * newHeight * components];
        var sums = new long[components];
        for (int y = 0; y < newHeight; y++)
        {
            int y0 = (int)((long)y * height / newHeight);
            int y1 = Math.Max(y0 + 1, (int)((long)(y + 1) * height / newHeight));
            for (int x = 0; x < newWidth; x++)
            {
                int x0 = (int)((long)x * width / newWidth);
                int x1 = Math.Max(x0 + 1, (int)((long)(x + 1) * width / newWidth));
                Array.Clear(sums);
                for (int sy = y0; sy < y1; sy++)
                {
                    int at = (sy * width + x0) * components;
                    for (int sx = x0; sx < x1; sx++)
                    {
                        for (int c = 0; c < components; c++) sums[c] += source[at++];
                    }
                }
                long count = (long)(y1 - y0) * (x1 - x0);
                int o = (y * newWidth + x) * components;
                for (int c = 0; c < components; c++) result[o + c] = (byte)((sums[c] + count / 2) / count);
            }
        }
        return result;
    }

    public static byte Luminance(int r, int g, int b) => (byte)((299 * r + 587 * g + 114 * b + 500) / 1000);
}

/// <summary>The lowest resolution an image XObject has anywhere it is painted, in pixels per inch along each side: the use that stretches it most decides how many pixels it needs.</summary>
internal sealed class Placement
{
    public double DpiX = double.MaxValue, DpiY = double.MaxValue;
}

// Where each image is painted and how big: the real resolution is pixels over the placed size.
internal sealed class PlacedImages : ContentVisitor
{
    private readonly Dictionary<PdfStream, Placement> _found = new(ReferenceEqualityComparer.Instance);

    public static Dictionary<PdfStream, Placement> Measure(PdfDocument document)
    {
        var visitor = new PlacedImages();
        var interpreter = new ContentInterpreter(document);
        foreach (var page in document.Pages)
        {
            interpreter.Run(page, visitor);
            foreach (var (form, matrix) in PageAppearances.Of(document, page)) interpreter.Run(form, visitor, matrix);
        }
        return visitor._found;
    }

    public override void PaintImage(ContentContext context, ImageInfo image)
    {
        if (image.Stream is not { } stream || image.IsMask) return;
        double across = double.Hypot(image.Matrix.A, image.Matrix.B), down = double.Hypot(image.Matrix.C, image.Matrix.D);
        if (across < 1e-6 || down < 1e-6) return;
        if (!_found.TryGetValue(stream, out var placement)) _found[stream] = placement = new Placement();
        placement.DpiX = Math.Min(placement.DpiX, image.Width * 72 / across);
        placement.DpiY = Math.Min(placement.DpiY, image.Height * 72 / down);
    }
}
