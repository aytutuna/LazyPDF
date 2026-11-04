namespace LazyPDF.Core;

/// <summary>
/// Puts the colour space, /Decode, colour key and mask of an image on its pixels, whether the
/// samples came out of the filters or out of an image codec. A mask stored with a codec of its own
/// goes through the codec too (ISO 32000-1 8.9.6).
/// </summary>
internal sealed class ExportImageMerge(PdfDocument document, IImageCodec? codec, long pixelBudget)
{
    private static readonly string[] Coders = ["DCTDecode", "DCT", "JPXDecode", "JBIG2Decode"];

    private long _pixels;

    /// <summary>Counts pixels about to be decoded; past the budget it throws, and the picture is left out.</summary>
    public void Charge(long pixels)
    {
        _pixels += pixels;
        if (_pixels > pixelBudget) throw new PdfReadException(PdfReadProblem.Unsupported, ExportText.TooLarge);
    }

    /// <summary>True when a JPEG file made of the image's data shows what the page shows.</summary>
    public bool ShowsAsFile(PdfDictionary dictionary)
    {
        if (Present(dictionary["SMask"]) || Present(dictionary["Mask"]) || document.Bool(dictionary, "ImageMask") == true) return false;
        if (PdfFunction.Numbers(dictionary["Decode"], document.Resolve) is { } decode && !decode.Chunk(2).All(pair => pair is [0, 1])) return false;
        try
        {
            return Space(dictionary) is null or SampleColorSpace.Gray or SampleColorSpace.Rgb or SampleColorSpace.Cmyk;
        }
        catch (PdfReadException)
        {
            return true;
        }
    }

    public PdfRgbaImage FromSamples(PdfDictionary dictionary, byte[] samples)
    {
        var (plain, mask, stencil) = Split(dictionary, all: false);
        return Apply(PdfImageSamples.ToRgba(plain, samples, document.Resolve, document.Data), mask, stencil);
    }

    /// <summary>
    /// <paramref name="pixels"/> are the codec's, sRGB already. A space of one or three components is
    /// given back to the samples code as samples, so /Decode, the tint transform and a colour key apply
    /// as for any image. Any other space, and one that cannot be read, is taken as the codec left it:
    /// the ink values of a CMYK or DeviceN image cannot be told from its RGB, and a codec that reads
    /// the Adobe marker has applied the inversion that /Decode of such a file stands for.
    /// </summary>
    public PdfRgbaImage FromPixels(PdfDictionary dictionary, PdfRgbaImage pixels, string coder)
    {
        bool imageMask = document.Bool(dictionary, "ImageMask") == true;
        SampleColorSpace? space = null;
        bool readable = true;
        try
        {
            if (!imageMask) space = Space(dictionary);
        }
        catch (PdfReadException)
        {
            readable = false;
        }
        int n = imageMask ? 1 : space?.Components ?? 3;
        bool samples = readable && n is 1 or 3;
        var (plain, mask, stencil) = Split(dictionary, all: !samples);
        if (!samples) return Apply(pixels, mask, stencil);

        plain["Width"] = new PdfNumber(pixels.Width);
        plain["Height"] = new PdfNumber(pixels.Height);
        // /Decode does not apply to JPEG 2000 data (ISO 32000-1 Table 89).
        if (coder == "JPXDecode" && !imageMask) plain.Remove("Decode");
        bool bits = imageMask || coder == "JBIG2Decode";
        if (!imageMask) plain["BitsPerComponent"] = new PdfNumber(bits ? 1 : 8);

        var converted = PdfImageSamples.ToRgba(plain, Pack(pixels, n, bits), document.Resolve, document.Data);
        if (coder == "JPXDecode" && document.Integer(dictionary, "SMaskInData") is > 0)
        {
            for (int i = 3; i < converted.Rgba.Length; i += 4) converted.Rgba[i] = (byte)(converted.Rgba[i] * pixels.Rgba[i] / 255);
        }
        return Apply(converted, mask, stencil);
    }

    private bool Present(PdfObject? value) => document.Resolve(value) is not (null or PdfNull);

    private SampleColorSpace? Space(PdfDictionary dictionary) =>
        Present(dictionary["ColorSpace"]) ? SampleColorSpace.Parse(dictionary["ColorSpace"], document.Resolve, document.Data) : null;

    // The samples code applies a mask of plain filters itself; the rest is left for Apply.
    private (PdfDictionary Plain, PdfStream? Mask, bool Stencil) Split(PdfDictionary dictionary, bool all)
    {
        var plain = dictionary.Copy();
        if (document.Resolve(dictionary["SMask"]) is PdfStream soft)
        {
            ChargeMask(soft);
            if (!all && !IsCoded(soft)) return (plain, null, false);
            plain.Remove("SMask");
            return (plain, soft, false);
        }
        if (document.Resolve(dictionary["Mask"]) is PdfStream hard)
        {
            ChargeMask(hard);
            if (!all && !IsCoded(hard)) return (plain, null, false);
            plain.Remove("Mask");
            return (plain, hard, true);
        }
        return (plain, null, false);
    }

    // A coded mask is charged for what the codec returns; an unreadable size is refused later and costs nothing.
    private void ChargeMask(PdfStream mask)
    {
        if (IsCoded(mask)) return;
        long width = document.Integer(mask.Dictionary, "Width") ?? 0, height = document.Integer(mask.Dictionary, "Height") ?? 0;
        if (width >= 1 && height >= 1 && width <= PdfImageSamples.MaxPixels / height) Charge(width * height);
    }

    private bool IsCoded(PdfStream stream) => document.DecodeSpec(stream).Filter switch
    {
        PdfName name => Coders.Contains(name.Value),
        PdfArray array => array.Items.Any(i => i is PdfName name && Coders.Contains(name.Value)),
        _ => false,
    };

    private static byte[] Pack(PdfRgbaImage image, int components, bool bits)
    {
        int w = image.Width, h = image.Height;
        var rgba = image.Rgba;
        if (bits)
        {
            int row = (w + 7) / 8;
            var packed = new byte[row * h];
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    if (rgba[(y * w + x) * 4] >= 128) packed[y * row + x / 8] |= (byte)(0x80 >> (x % 8));
                }
            }
            return packed;
        }
        var samples = new byte[w * h * components];
        for (int i = 0; i < w * h; i++)
        {
            for (int c = 0; c < components; c++) samples[i * components + c] = rgba[i * 4 + c];
        }
        return samples;
    }

    // The alpha of the mask, sampled nearest where the sizes differ.
    private PdfRgbaImage Apply(PdfRgbaImage image, PdfStream? mask, bool stencil)
    {
        if (mask is null || Plane(mask, stencil) is not var (mw, mh, alpha)) return image;
        var rgba = (byte[])image.Rgba.Clone();
        for (int y = 0; y < image.Height; y++)
        {
            int row = (int)((long)y * mh / image.Height) * mw;
            for (int x = 0; x < image.Width; x++) rgba[(y * image.Width + x) * 4 + 3] = alpha[row + (int)((long)x * mw / image.Width)];
        }
        return new PdfRgbaImage(image.Width, image.Height, rgba);
    }

    // Null when a codec is needed and cannot read the mask: the picture stays opaque.
    private (int Width, int Height, byte[] Alpha)? Plane(PdfStream mask, bool stencil)
    {
        var (filter, parameters, _) = document.DecodeSpec(mask);
        var decoded = PdfFilters.DecodeToCodec(document.RawData(mask), filter, parameters);
        PdfRgbaImage? image;
        bool inverted = false;
        if (decoded.Codec is null)
        {
            image = PdfImageSamples.ToRgba(mask.Dictionary, decoded.Data, document.Resolve, document.Data);
        }
        else
        {
            Charge(0);
            image = codec?.Decode(decoded.Data, decoded.Codec);
            if (image is not null) Charge((long)image.Width * image.Height);
            inverted = PdfFunction.Numbers(mask.Dictionary["Decode"], document.Resolve) is [var low, var high, ..] && low > high;
        }
        if (image is null || (long)image.Width * image.Height > PdfImageSamples.MaxPixels) return null;

        // An image mask decoded from samples already says where it paints in its alpha.
        bool painted = decoded.Codec is null && document.Bool(mask.Dictionary, "ImageMask") == true;
        var alpha = new byte[image.Width * image.Height];
        for (int i = 0; i < alpha.Length; i++)
        {
            byte value = painted ? image.Rgba[i * 4 + 3] : inverted ? (byte)(255 - image.Rgba[i * 4]) : image.Rgba[i * 4];
            alpha[i] = stencil && !painted ? (value < 128 ? (byte)255 : (byte)0) : value;
        }
        return (image.Width, image.Height, alpha);
    }
}
