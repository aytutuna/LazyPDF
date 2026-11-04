using System.IO.Compression;

namespace LazyPDF.Core;

// Lowers the resolution of images that are placed bigger than needed, and stores black and white
// pictures in one bit. An image is only replaced when the new data is smaller. Each image keeps
// its colour space, /Decode and soft mask; what cannot be carried over is left as it is.
internal sealed class OptimizeImages(PdfDocument document, OptimizeOptions options, IImageCodec? codec)
{
    private const long MaxPixels = 16_000_000;

    private readonly HashSet<PdfStream> _done = new(ReferenceEqualityComparer.Instance);

    public int Bilevel { get; private set; }
    public int Downsampled { get; private set; }
    public bool NeedsCodec { get; private set; }

    public void Run()
    {
        var images = PdfGraph.Objects(document)
            .Select(o => o.Value as PdfStream)
            .Where(s => s is not null && document.Name(s.Dictionary, "Subtype") == "Image" && document.Bool(s.Dictionary, "ImageMask") != true)
            .Select(s => s!).ToList();
        if (options.BilevelTolerance >= 0)
        {
            foreach (var image in images)
            {
                if (TryBilevel(image)) Bilevel++;
            }
        }
        if (options.ImageDpi <= 0) return;
        var placements = PlacedImages.Measure(document);
        var untraced = Untraced();
        foreach (var image in images)
        {
            if (placements.TryGetValue(image, out var placement) && !untraced.Contains(image) && TryShrink(image, placement)) Downsampled++;
        }
    }

    // Images drawn by Type 3 glyph procedures are never walked, so their sizes are not known.
    private HashSet<PdfStream> Untraced()
    {
        var set = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            if (document.Name(dictionary, "Subtype") != "Type3") continue;
            foreach (var inner in PdfGraph.Dictionaries(document.Dict(dictionary, "Resources")))
            {
                foreach (var (_, value) in inner.Entries)
                {
                    if (document.Resolve(value) is PdfStream xobject) set.Add(xobject);
                }
            }
        }
        return set;
    }

    private bool TryBilevel(PdfStream stream)
    {
        var dictionary = stream.Dictionary;
        int width = (int)(document.Integer(dictionary, "Width") ?? 0), height = (int)(document.Integer(dictionary, "Height") ?? 0);
        if (width < 1 || height < 1 || (long)width * height > MaxPixels) return false;
        if (dictionary.ContainsKey("Decode") || document.Resolve(dictionary["Mask"]) is PdfArray || dictionary.ContainsKey("SMaskInData")) return false;
        var (family, _) = ImageKit.Describe(document, dictionary["ColorSpace"]);
        long bpc = document.Integer(dictionary, "BitsPerComponent") ?? 8;
        if (family is ImageFamily.Unknown or ImageFamily.Spot or ImageFamily.Lab || (bpc == 1 && family == ImageFamily.Gray)) return false;
        if (Samples(stream) is not { } samples) return false;
        var plain = dictionary.Copy();
        plain.Remove("SMask");
        plain.Remove("Mask");
        PdfRgbaImage pixels;
        try
        {
            pixels = PdfImageSamples.ToRgba(plain, samples, document.Resolve, s => document.Data(s));
        }
        catch (PdfReadException)
        {
            return false;
        }
        int low = options.BilevelTolerance, high = 255 - options.BilevelTolerance;
        int rowBytes = (width + 7) / 8;
        var bits = new byte[rowBytes * height];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int at = (y * width + x) * 4;
                int r = pixels.Rgba[at], g = pixels.Rgba[at + 1], b = pixels.Rgba[at + 2];
                if (r >= high && g >= high && b >= high) bits[y * rowBytes + x / 8] |= (byte)(0x80 >> x % 8);
                else if (r > low || g > low || b > low) return false;
            }
        }
        byte[] packed = PdfFilterEncoders.Flate(bits, CompressionLevel.SmallestSize);
        if (packed.Length >= document.RawData(stream).Length) return false;
        dictionary["ColorSpace"] = new PdfName("DeviceGray");
        dictionary["BitsPerComponent"] = new PdfNumber(1);
        dictionary["Filter"] = new PdfName("FlateDecode");
        dictionary.Remove("DecodeParms");
        stream.Data = packed;
        return true;
    }

    // The data with every filter undone; null for an image codec, which the caller handles.
    private byte[]? Samples(PdfStream stream)
    {
        var (filter, parameters, _) = document.DecodeSpec(stream);
        try
        {
            var decoded = PdfFilters.DecodeToCodec(document.RawData(stream), filter, parameters);
            return decoded.Codec is null ? decoded.Data : null;
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    private bool TryShrink(PdfStream stream, Placement placement)
    {
        var dictionary = stream.Dictionary;
        int width = (int)(document.Integer(dictionary, "Width") ?? 0), height = (int)(document.Integer(dictionary, "Height") ?? 0);
        if (width < 1 || height < 1 || (long)width * height > PdfImageSamples.MaxPixels) return false;
        double above = Math.Max(options.ImageDpiAbove, options.ImageDpi);
        if (placement.DpiX <= above && placement.DpiY <= above) return false;
        int newWidth = Math.Max(1, (int)Math.Round(width * Math.Min(1, options.ImageDpi / placement.DpiX)));
        int newHeight = Math.Max(1, (int)Math.Round(height * Math.Min(1, options.ImageDpi / placement.DpiY)));
        if ((long)newWidth * newHeight > 0.9 * width * height) return false;
        if (dictionary.ContainsKey("SMaskInData") || document.Resolve(dictionary["Mask"]) is not null) return false;
        if (!_done.Add(stream)) return false;

        bool replaced = Shrink(stream, width, height, newWidth, newHeight);
        if (replaced && document.Resolve(dictionary["SMask"]) is PdfStream soft && _done.Add(soft))
        {
            int mw = (int)(document.Integer(soft.Dictionary, "Width") ?? 0), mh = (int)(document.Integer(soft.Dictionary, "Height") ?? 0);
            if (mw > 0 && mh > 0) Shrink(soft, mw, mh, Math.Max(1, (int)((long)mw * newWidth / width)), Math.Max(1, (int)((long)mh * newHeight / height)));
        }
        return replaced;
    }

    private bool Shrink(PdfStream stream, int width, int height, int newWidth, int newHeight)
    {
        var dictionary = stream.Dictionary;
        var (filter, parameters, _) = document.DecodeSpec(stream);
        PdfDecodedStream decoded;
        try
        {
            decoded = PdfFilters.DecodeToCodec(document.RawData(stream), filter, parameters);
        }
        catch (PdfReadException)
        {
            return false;
        }
        var (family, components) = ImageKit.Describe(document, dictionary["ColorSpace"]);
        long bpc = document.Integer(dictionary, "BitsPerComponent") ?? 8;
        if (decoded.Codec is "DCTDecode" or "JPXDecode") return ShrinkCoded(stream, decoded, family, components, newWidth, newHeight);
        if (decoded.Codec is not null || bpc == 1 || bpc is not (2 or 4 or 8 or 16)) return false;

        byte[] pixels;
        if (family == ImageFamily.Indexed)
        {
            var plain = dictionary.Copy();
            plain.Remove("SMask");
            try
            {
                pixels = RgbOf(PdfImageSamples.ToRgba(plain, decoded.Data, document.Resolve, s => document.Data(s)));
            }
            catch (PdfReadException)
            {
                return false;
            }
            components = 3;
        }
        else if (components > 0 && family != ImageFamily.Unknown)
        {
            pixels = ImageKit.Unpack(decoded.Data, width, height, components, (int)bpc);
        }
        else
        {
            return false;
        }
        byte[] smaller = PdfFilterEncoders.Flate(ImageKit.Shrink(pixels, width, height, components, newWidth, newHeight), CompressionLevel.SmallestSize);
        if (smaller.Length >= document.RawData(stream).Length) return false;
        Store(stream, newWidth, newHeight, smaller, "FlateDecode");
        if (family == ImageFamily.Indexed)
        {
            dictionary["ColorSpace"] = new PdfName("DeviceRGB");
            dictionary.Remove("Decode");
        }
        return true;
    }

    private bool ShrinkCoded(PdfStream stream, PdfDecodedStream decoded, ImageFamily family, int components, int newWidth, int newHeight)
    {
        var dictionary = stream.Dictionary;
        bool jpx = decoded.Codec == "JPXDecode";
        if (dictionary.ContainsKey("Decode") || (!jpx && family is not (ImageFamily.Gray or ImageFamily.Rgb))) return false;
        if (jpx && family is not (ImageFamily.Gray or ImageFamily.Rgb or ImageFamily.Unknown)) return false;
        if (codec is null)
        {
            NeedsCodec = true;
            return false;
        }
        var image = codec.Decode(decoded.Data, decoded.Codec!);
        if (image is null || (long)image.Width * image.Height > MaxPixels) return false;
        var rgb = new byte[image.Width * image.Height * 3];
        for (int i = 0, o = 0; i < image.Width * image.Height; i++)
        {
            rgb[o++] = image.Rgba[4 * i];
            rgb[o++] = image.Rgba[4 * i + 1];
            rgb[o++] = image.Rgba[4 * i + 2];
        }
        var small = ImageKit.Shrink(rgb, image.Width, image.Height, 3, newWidth, newHeight);
        var rgba = new byte[newWidth * newHeight * 4];
        for (int i = 0; i < newWidth * newHeight; i++)
        {
            rgba[4 * i] = small[3 * i];
            rgba[4 * i + 1] = small[3 * i + 1];
            rgba[4 * i + 2] = small[3 * i + 2];
            rgba[4 * i + 3] = 255;
        }
        byte[] jpeg = codec.EncodeJpeg(new PdfRgbaImage(newWidth, newHeight, rgba), Math.Clamp(options.JpegQuality, 1, 100));
        if (jpeg.Length >= document.RawData(stream).Length) return false;
        Store(stream, newWidth, newHeight, jpeg, "DCTDecode");
        if (family != ImageFamily.Rgb || components != 3) dictionary["ColorSpace"] = new PdfName("DeviceRGB");
        return true;
    }

    private static byte[] RgbOf(PdfRgbaImage image)
    {
        var rgb = new byte[image.Width * image.Height * 3];
        for (int i = 0, o = 0; i < image.Width * image.Height; i++)
        {
            rgb[o++] = image.Rgba[4 * i];
            rgb[o++] = image.Rgba[4 * i + 1];
            rgb[o++] = image.Rgba[4 * i + 2];
        }
        return rgb;
    }

    private static void Store(PdfStream stream, int width, int height, byte[] data, string filter)
    {
        var dictionary = stream.Dictionary;
        dictionary["Width"] = new PdfNumber(width);
        dictionary["Height"] = new PdfNumber(height);
        dictionary["BitsPerComponent"] = new PdfNumber(8);
        dictionary["Filter"] = new PdfName(filter);
        dictionary.Remove("DecodeParms");
        stream.Data = data;
    }
}
