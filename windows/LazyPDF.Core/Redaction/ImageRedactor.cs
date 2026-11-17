namespace LazyPDF.Core;

/// <summary>
/// Makes a private copy of an image with the pixels under the marks overwritten in the samples, so
/// the covered picture is gone rather than hidden. The copy is stored with Flate. Pictures in a
/// lossy codec go through the system's decoder; with none, or when it fails, nothing is
/// returned and the caller removes the image.
/// </summary>
internal sealed class ImageRedactor(PdfDocument document, IImageCodec? codec)
{
    private const long MaxSamples = 256L << 20;
    private const int MaxMaskDepth = 2;
    private static readonly string[] MaskKeys = ["SMask", "Mask"];
    // What describes the picture itself (ISO 32000-1 8.9.5); anything else on the dictionary can lead back to the original.
    private static readonly string[] Kept = ["Type", "Subtype", "Width", "Height", "ColorSpace", "BitsPerComponent", "Intent", "ImageMask", "Mask", "Decode", "Interpolate", "SMask", "SMaskInData", "Matte", "StructParent", "OC"];

    /// <summary>The soft mask and stencil mask of a picture, and theirs in turn as far as <see cref="Redact"/> copies: the streams a cut makes private copies of.</summary>
    public static IEnumerable<PdfStream> Masks(PdfDocument document, PdfStream image, int depth = 0)
    {
        if (depth > MaxMaskDepth) yield break;
        foreach (string key in MaskKeys)
        {
            if (document.Stream(image.Dictionary, key) is not { } mask) continue;
            yield return mask;
            foreach (var inner in Masks(document, mask, depth + 1)) yield return inner;
        }
    }

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

    private PdfReference? Copy(PdfStream image, List<List<(double X, double Y)>> unit, int depth, bool soft = false)
    {
        // A mask has no masks of its own to speak of; a loop of them is a trap.
        if (depth > MaxMaskDepth) return null;
        var d = image.Dictionary;
        var (filter, parameters, _) = document.DecodeSpec(image, decoding: true);
        var decoded = PdfFilters.DecodeToCodecWhole(document.RawData(image), filter, parameters, MaxSamples);
        var copy = new PdfDictionary();
        foreach (string key in Kept)
        {
            if (d[key] is { } value) copy[key] = value;
        }
        copy["Filter"] = new PdfName("FlateDecode");
        // A coded soft mask is written back as plain gray, which has no soft mask of its own to cut.
        if (!(soft && decoded.Codec is not null) && !Masks(d, copy, unit, depth)) return null;

        if (decoded.Codec is null)
        {
            int width = (int)(document.Integer(d, "Width") ?? 0), height = (int)(document.Integer(d, "Height") ?? 0);
            if (!Fits(width, height)) return null;
            bool mask = document.Bool(d, "ImageMask") == true;
            int bits = mask ? 1 : (int)(document.Integer(d, "BitsPerComponent") ?? 8);
            int components = mask ? 1 : SampleColorSpace.Parse(d["ColorSpace"], document.Resolve, s => document.Data(s)).Components;
            var samples = decoded.Data;
            long used = ((long)width * components * bits + 7) / 8 * height;
            // A JBIG2 page is fitted to the picture's size, but not to a depth or colour space it does not have; other rows would put the marks in the wrong place.
            if (PdfFilters.Uses(filter, "JBIG2Decode") && samples.Length != used) return null;
            if (samples.Length > used) samples = samples[..(int)used];
            Zero(samples, width, height, components * bits, unit);
            return document.Add(new PdfStream(copy, PdfFilterEncoders.Flate(samples)));
        }

        // A picture whose colour space the pixels cannot show is not rewritten: the caller removes it.
        bool jpx = decoded.Codec == "JPXDecode";
        if (jpx && !JpxImage.Readable(document, d)) return null;
        if (codec?.Decode(decoded.Data, decoded.Codec, jpx ? JpxImage.Components(document, d) : 0) is not { } pixels || !Fits(pixels.Width, pixels.Height)) return null;
        if (jpx)
        {
            long mode = JpxImage.MaskInData(document, d);
            if (mode <= 0 && !JpxImage.Opaque(pixels)) return null;
            pixels = JpxImage.Alpha(pixels, mode);
        }
        else if (!soft)
        {
            if (WithDecode(d, decoded.Data, pixels) is not { } decodedPixels) return null;
            pixels = decodedPixels;
        }
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
        if (soft)
        {
            // ISO 32000-1 11.6.5.2: a soft mask is a DeviceGray image, 8 bits, with no /SMask or /Mask; /Matte stays.
            var gray = new byte[pixels.Width * pixels.Height];
            for (int i = 0; i < gray.Length; i++) gray[i] = rgba[4 * i];
            copy["Width"] = new PdfNumber(pixels.Width);
            copy["Height"] = new PdfNumber(pixels.Height);
            copy["ColorSpace"] = new PdfName("DeviceGray");
            copy["BitsPerComponent"] = new PdfNumber(8);
            foreach (string key in (ReadOnlySpan<string>)["SMask", "Mask", "SMaskInData"]) copy.Remove(key);
            if (jpx) copy.Remove("Decode");
            return document.Add(new PdfStream(copy, PdfFilterEncoders.Flate(gray)));
        }
        FitMatte(copy, JpxImage.Components(document, d));
        var reference = ContentImages.AddRgba(document, pixels.Width, pixels.Height, rgba);
        var made = (PdfStream)document.Get(reference.Number)!;
        foreach (string key in (ReadOnlySpan<string>)["SMask", "Mask"])
        {
            if (copy[key] is { } mask) made.Dictionary[key] = mask;
        }
        return reference;
    }

    // A picture of a DCT file is written back as RGB with no /Decode, so the /Decode goes onto the codec's samples first. That
    // works where a codec channel is a component of the colour space: gray, which the codec gives as R = G = B, and RGB. A CMYK
    // picture keeps what the codec made of it only under the inversion the Adobe marker already undid; any other /Decode on a
    // picture the codec converted cannot be carried over, so the picture is one that cannot be decoded here.
    private PdfRgbaImage? WithDecode(PdfDictionary image, byte[] jpeg, PdfRgbaImage pixels)
    {
        var decode = PdfFunction.Numbers(image["Decode"], document.Resolve);
        if (decode is null || decode.Chunk(2).All(pair => pair is [0, 1])) return pixels;
        var (family, components) = ImageKit.Describe(document, image["ColorSpace"]);
        if (family == ImageFamily.Cmyk) return ExportImageMerge.Inverts(decode) && ExportImageMerge.HasAdobeMarker(jpeg) ? pixels : null;
        if (family is not (ImageFamily.Gray or ImageFamily.Rgb)) return null;
        if (decode.Length < 2 * components) return pixels;
        var rgba = (byte[])pixels.Rgba.Clone();
        for (int i = 0; i < rgba.Length; i += 4)
        {
            for (int c = 0; c < 3; c++)
            {
                int j = components == 1 ? 0 : c;
                double value = decode[2 * j] + rgba[i + c] * (decode[2 * j + 1] - decode[2 * j]) / 255;
                rgba[i + c] = (byte)(Math.Clamp(value, 0, 1) * 255 + 0.5);
            }
        }
        return new PdfRgbaImage(pixels.Width, pixels.Height, rgba, pixels.DpiX, pixels.DpiY);
    }

    // The picture is written back as RGB, so a matte stays only as three entries: a gray picture's one is repeated, any other is
    // dropped. With no colour space (0 components) the length of the matte is all there is to go by.
    private void FitMatte(PdfDictionary image, int components)
    {
        if (document.Stream(image, "SMask") is not { } soft || document.Array(soft.Dictionary, "Matte") is not { } matte || matte.Items.Count == 3) return;
        if (matte.Items.Count == 1 && components is 0 or 1) soft.Dictionary["Matte"] = new PdfArray([.. Enumerable.Repeat(matte.Items[0], 3)]);
        else soft.Dictionary.Remove("Matte");
    }

    private static bool Fits(int width, int height) => width > 0 && height > 0 && (long)width * height <= PdfImageSamples.MaxPixels;

    // The soft mask and the stencil mask hold picture data of their own, at their own size.
    private bool Masks(PdfDictionary source, PdfDictionary copy, List<List<(double X, double Y)>> unit, int depth)
    {
        foreach (string key in (ReadOnlySpan<string>)["SMask", "Mask"])
        {
            if (document.Stream(source, key) is not { } mask) continue;
            var reference = Copy(mask, unit, depth + 1, key == "SMask");
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
