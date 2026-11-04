namespace LazyPDF.Core;

/// <summary>
/// Makes a private copy of an image with the pixels under the marks overwritten in the samples, so
/// the covered picture is gone rather than hidden. The copy is stored with Flate. Pictures in a
/// lossy or bilevel codec go through the system's decoder; with none, or when it fails, nothing is
/// returned and the caller removes the image.
/// </summary>
internal sealed class ImageRedactor(PdfDocument document, IImageCodec? codec)
{
    private const long MaxSamples = 256L << 20;
    private const int MaxMaskDepth = 2;
    // What describes the picture itself (ISO 32000-1 8.9.5); anything else on the dictionary can lead back to the original.
    private static readonly string[] Kept = ["Type", "Subtype", "Width", "Height", "ColorSpace", "BitsPerComponent", "Intent", "ImageMask", "Mask", "Decode", "Interpolate", "SMask", "SMaskInData", "StructParent", "OC"];

    public PdfReference? Redact(PdfStream image, IReadOnlyList<MarkArea> areas, PdfMatrix placement)
    {
        if (placement.Invert() is not { } back) return null;
        var unit = areas.Select(a => a.Points.Select(p => back.Transform(p.X, p.Y)).ToList()).ToList();
        try
        {
            return Copy(image, unit, 0);
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    private PdfReference? Copy(PdfStream image, List<List<(double X, double Y)>> unit, int depth)
    {
        // A mask has no masks of its own to speak of; a loop of them is a trap.
        if (depth > MaxMaskDepth) return null;
        var d = image.Dictionary;
        var (filter, parameters, _) = document.DecodeSpec(image);
        var decoded = PdfFilters.DecodeToCodec(document.RawData(image), filter, parameters, MaxSamples);
        var copy = new PdfDictionary();
        foreach (string key in Kept)
        {
            if (d[key] is { } value) copy[key] = value;
        }
        copy["Filter"] = new PdfName("FlateDecode");
        if (!Masks(d, copy, unit, depth)) return null;

        if (decoded.Codec is null)
        {
            int width = (int)(document.Integer(d, "Width") ?? 0), height = (int)(document.Integer(d, "Height") ?? 0);
            if (!Fits(width, height)) return null;
            bool mask = document.Bool(d, "ImageMask") == true;
            int bits = mask ? 1 : (int)(document.Integer(d, "BitsPerComponent") ?? 8);
            int components = mask ? 1 : SampleColorSpace.Parse(d["ColorSpace"], document.Resolve, s => document.Data(s)).Components;
            var samples = decoded.Data;
            long used = ((long)width * components * bits + 7) / 8 * height;
            if (samples.Length > used) samples = samples[..(int)used];
            Zero(samples, width, height, components * bits, unit);
            return document.Add(new PdfStream(copy, PdfFilterEncoders.Flate(samples)));
        }

        if (codec?.Decode(decoded.Data, decoded.Codec) is not { } pixels || !Fits(pixels.Width, pixels.Height)) return null;
        var rgba = pixels.Rgba;
        var cells = Cells(pixels.Width, pixels.Height, pixels.Height, unit);
        foreach (var (row, from, to) in cells)
        {
            for (int x = from; x < to; x++)
            {
                int i = (row * pixels.Width + x) * 4;
                (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]) = (0, 0, 0, 255);
            }
        }
        if (decoded.Codec == "JBIG2Decode")
        {
            copy["Width"] = new PdfNumber(pixels.Width);
            copy["Height"] = new PdfNumber(pixels.Height);
            return document.Add(new PdfStream(copy, PdfFilterEncoders.Flate(Bilevel(rgba, pixels.Width, pixels.Height))));
        }
        var reference = ContentImages.AddRgba(document, pixels.Width, pixels.Height, rgba);
        var made = (PdfStream)document.Get(reference.Number)!;
        foreach (string key in (ReadOnlySpan<string>)["SMask", "Mask"])
        {
            if (copy[key] is { } mask) made.Dictionary[key] = mask;
        }
        return reference;
    }

    private static bool Fits(int width, int height) => width > 0 && height > 0 && (long)width * height <= PdfImageSamples.MaxPixels;

    // The soft mask and the stencil mask hold picture data of their own, at their own size.
    private bool Masks(PdfDictionary source, PdfDictionary copy, List<List<(double X, double Y)>> unit, int depth)
    {
        foreach (string key in (ReadOnlySpan<string>)["SMask", "Mask"])
        {
            if (document.Stream(source, key) is not { } mask) continue;
            var reference = Copy(mask, unit, depth + 1);
            if (reference is null) return false;
            copy[key] = reference;
        }
        return true;
    }

    private static void Zero(byte[] data, int width, int height, int bitsPerPixel, List<List<(double X, double Y)>> unit)
    {
        long stride = ((long)width * bitsPerPixel + 7) / 8;
        int rows = (int)Math.Min(height, (data.Length + stride - 1) / Math.Max(stride, 1));
        foreach (var (row, from, to) in Cells(width, rows, height, unit))
        {
            long start = row * stride;
            if (start >= data.Length) continue;
            long bitFrom = (long)from * bitsPerPixel, bitTo = (long)to * bitsPerPixel;
            for (long b = bitFrom / 8; b <= (bitTo - 1) / 8; b++)
            {
                if (start + b >= data.Length) break;
                int lo = (int)(Math.Max(bitFrom, b * 8) - b * 8), hi = (int)(Math.Min(bitTo, b * 8 + 8) - b * 8);
                data[start + b] &= (byte)~((0xFF >> lo) & (0xFF << (8 - hi)));
            }
        }
    }

    private static byte[] Bilevel(byte[] rgba, int width, int height)
    {
        int stride = (width + 7) / 8;
        var bits = new byte[stride * height];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int i = (y * width + x) * 4;
                if (rgba[i] + rgba[i + 1] + rgba[i + 2] >= 384) bits[y * stride + x / 8] |= (byte)(0x80 >> (x % 8));
            }
        }
        return bits;
    }

    /// <summary>The runs of pixels, per row, that any part of a marked polygon touches. The polygons are in the unit square, y up.</summary>
    private static IEnumerable<(int Row, int From, int To)> Cells(int width, int rows, int height, List<List<(double X, double Y)>> unit)
    {
        foreach (var polygon in unit)
        {
            var pixels = polygon.Select(p => (X: p.X * width, Y: (1 - p.Y) * height)).ToList();
            int top = (int)Math.Max(0, Math.Floor(pixels.Min(p => p.Y))), bottom = (int)Math.Min(rows, Math.Ceiling(pixels.Max(p => p.Y)));
            for (int row = top; row < bottom; row++)
            {
                var strip = Half(Half(pixels, p => p.Y - row), p => row + 1 - p.Y);
                if (strip.Count < 3 || Geometry.Area(strip) < 1e-6) continue;
                int from = (int)Math.Max(0, Math.Floor(strip.Min(p => p.X))), to = (int)Math.Min(width, Math.Ceiling(strip.Max(p => p.X)));
                if (to > from) yield return (row, from, to);
            }
        }
    }

    // The part of a polygon on the side where the measure is not negative.
    private static List<(double X, double Y)> Half(List<(double X, double Y)> polygon, Func<(double X, double Y), double> measure)
    {
        var output = new List<(double X, double Y)>();
        for (int i = 0; i < polygon.Count; i++)
        {
            var (cur, prev) = (polygon[i], polygon[(i + polygon.Count - 1) % polygon.Count]);
            double mc = measure(cur), mp = measure(prev);
            if ((mc >= 0) != (mp >= 0))
            {
                double t = mp / (mp - mc);
                output.Add((prev.X + t * (cur.X - prev.X), prev.Y + t * (cur.Y - prev.Y)));
            }
            if (mc >= 0) output.Add(cur);
        }
        return output;
    }
}
