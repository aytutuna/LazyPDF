using System.IO.Compression;

namespace LazyPDF.Core;

// Lowers the resolution of images that are placed bigger than needed, and stores black and white
// pictures in one bit. An image is only replaced when the new data is smaller. Each image keeps
// its colour space, /Decode and soft mask; what cannot be carried over is left as it is.
internal sealed class OptimizeImages(PdfDocument document, OptimizeOptions options, IImageCodec? codec)
{
    private const long MaxPixels = 16_000_000;

    // Unpack holds every sample of the image; a row is limited as PdfImageSamples limits it.
    private const long MaxSamples = 1L << 28;
    private const long MaxRowSamples = 1L << 26;

    private readonly HashSet<PdfStream> _done = new(ReferenceEqualityComparer.Instance);

    public int Bilevel { get; private set; }
    public int Downsampled { get; private set; }
    public bool NeedsCodec { get; private set; }

    /// <summary>Some image was left at its size because a use of it could not be measured.</summary>
    public bool Partial { get; private set; }

    public void Run(CancellationToken cancel)
    {
        var images = PdfGraph.Objects(document)
            .Select(o => o.Value as PdfStream)
            .Where(s => s is not null && document.Name(s.Dictionary, "Subtype") == "Image" && document.Bool(s.Dictionary, "ImageMask") != true)
            .Select(s => s!).ToList();
        if (options.BilevelTolerance >= 0)
        {
            foreach (var image in images)
            {
                cancel.ThrowIfCancellationRequested();
                if (TryBilevel(image)) Bilevel++;
            }
        }
        if (options.ImageDpi <= 0) return;
        var placed = PlacedImages.Measure(document);
        if (!placed.Complete)
        {
            Partial = images.Any(i => !placed.Found.TryGetValue(i, out var seen) || Exceeds(seen));
            return;
        }
        var unseen = Unseen(placed);
        foreach (var image in images)
        {
            cancel.ThrowIfCancellationRequested();
            if (!placed.Found.TryGetValue(image, out var placement)) continue;
            if (unseen.Contains(image)) Partial |= Exceeds(placement);
            else if (TryShrink(image, placement)) Downsampled++;
        }
    }

    // Images listed by resources the walk never reached, and by the forms, patterns and soft mask groups those
    // use, may be painted somewhere nobody measured (a Type 3 glyph, an appearance state not shown).
    private HashSet<PdfStream> Unseen(PlacedImages walk)
    {
        var set = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        var visited = new HashSet<PdfStream>(ReferenceEqualityComparer.Instance);
        var forms = new Stack<PdfStream>();
        void Enter(PdfObject? value)
        {
            if (document.Resolve(value) is PdfStream stream && OptimizeWalk.IsForm(document, stream) && visited.Add(stream)) forms.Push(stream);
        }
        void List(PdfDictionary? resources)
        {
            foreach (var (_, value) in document.Dict(resources, "XObject")?.Entries ?? [])
            {
                if (document.Resolve(value) is not PdfStream xobject) continue;
                set.Add(xobject);
                Enter(xobject);
            }
            foreach (var (_, value) in document.Dict(resources, "Pattern")?.Entries ?? []) Enter(value);
            foreach (var (_, value) in document.Dict(resources, "ExtGState")?.Entries ?? [])
            {
                if (document.Dict(document.Resolve(value) as PdfDictionary, "SMask") is { } mask) Enter(mask["G"]);
            }
        }
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            if (document.Dict(dictionary, "Resources") is { } resources && !walk.Reached(resources)) List(resources);
        }
        while (forms.Count > 0) List(document.Dict(forms.Pop().Dictionary, "Resources"));
        return set;
    }

    private bool Exceeds(Placement placement)
    {
        double above = Math.Max(options.ImageDpiAbove, options.ImageDpi);
        return placement.DpiX > above || placement.DpiY > above;
    }

    private bool TryBilevel(PdfStream stream)
    {
        var dictionary = stream.Dictionary;
        int width = (int)(document.Integer(dictionary, "Width") ?? 0), height = (int)(document.Integer(dictionary, "Height") ?? 0);
        if (width < 1 || height < 1 || (long)width * height > MaxPixels) return false;
        if (dictionary.ContainsKey("Decode") || document.Resolve(dictionary["Mask"]) is PdfArray || dictionary.ContainsKey("SMaskInData") || HasMatte(dictionary)) return false;
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
        if (!Exceeds(placement)) return false;
        int newWidth = Math.Max(1, (int)Math.Round(width * Math.Min(1, options.ImageDpi / placement.DpiX)));
        int newHeight = Math.Max(1, (int)Math.Round(height * Math.Min(1, options.ImageDpi / placement.DpiY)));
        if ((long)newWidth * newHeight > 0.9 * width * height) return false;
        if (dictionary.ContainsKey("SMaskInData") || document.Resolve(dictionary["Mask"]) is not null) return false;
        var soft = document.Resolve(dictionary["SMask"]) as PdfStream;
        int maskWidth = (int)(document.Integer(soft?.Dictionary, "Width") ?? 0), maskHeight = (int)(document.Integer(soft?.Dictionary, "Height") ?? 0);
        // A matte only fits a mask of the image's own size, which a failed mask shrink would break.
        if (soft is not null && (HasMatte(dictionary) || (long)maskWidth * maskHeight > PdfImageSamples.MaxPixels)) return false;
        if (!_done.Add(stream)) return false;

        bool replaced = Shrink(stream, width, height, newWidth, newHeight);
        if (replaced && soft is not null && maskWidth > 0 && maskHeight > 0 && _done.Add(soft))
        {
            Shrink(soft, maskWidth, maskHeight, Math.Max(1, (int)((long)maskWidth * newWidth / width)), Math.Max(1, (int)((long)maskHeight * newHeight / height)));
        }
        return replaced;
    }

    private bool HasMatte(PdfDictionary image) => document.Resolve(image["SMask"]) is PdfStream soft && soft.Dictionary.ContainsKey("Matte");

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
        else if (components > 0 && family != ImageFamily.Unknown && (long)width * components <= MaxRowSamples && (long)width * height * components <= MaxSamples)
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
        if (image is null || image.Width < 1 || image.Height < 1 || (long)image.Width * image.Height > MaxPixels) return false;
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
