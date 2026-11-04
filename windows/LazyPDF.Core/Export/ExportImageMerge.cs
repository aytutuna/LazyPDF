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

    /// <summary>True when a JPEG file made of <paramref name="jpeg"/> shows what the page shows.</summary>
    public bool ShowsAsFile(PdfDictionary dictionary, byte[] jpeg)
    {
        if (Present(dictionary["SMask"]) || Present(dictionary["Mask"]) || document.Bool(dictionary, "ImageMask") == true) return false;
        var decode = PdfFunction.Numbers(dictionary["Decode"], document.Resolve);
        bool identity = decode is null || decode.Chunk(2).All(pair => pair is [0, 1]);
        try
        {
            var space = Space(dictionary);
            if (space is SampleColorSpace.Cmyk) return identity ? !HasAdobeMarker(jpeg) : Inverts(decode) && HasAdobeMarker(jpeg);
            return identity && space is null or SampleColorSpace.Gray or SampleColorSpace.Rgb;
        }
        catch (PdfReadException)
        {
            return identity;
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
    /// the inks of a DeviceN image cannot be recovered from its RGB. A CMYK image is brought to what
    /// the page shows (see <see cref="CmykView"/>). <paramref name="coded"/> is the codec's input.
    /// </summary>
    public PdfRgbaImage FromPixels(PdfDictionary dictionary, PdfRgbaImage pixels, string coder, byte[] coded)
    {
        if (coder == "JPXDecode") pixels = JpxAlpha(pixels, document.Integer(dictionary, "SMaskInData") ?? 0);
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
        if (!samples)
        {
            if (space is { Components: 4 }) pixels = CmykView(dictionary, pixels, space, coder == "DCTDecode" && HasAdobeMarker(coded));
            return Apply(pixels, mask, stencil);
        }

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

    // ISO 32000-1 Table 89: 0 leaves the codestream's alpha out, 1 takes it as straight alpha, 2 as premultiplied.
    private static PdfRgbaImage JpxAlpha(PdfRgbaImage image, long mode)
    {
        if (mode == 1) return image;
        var rgba = (byte[])image.Rgba.Clone();
        for (int i = 3; i < rgba.Length; i += 4)
        {
            int alpha = rgba[i];
            if (mode < 1) rgba[i] = 255;
            else if (alpha is > 0 and < 255)
            {
                for (int c = 1; c <= 3; c++) rgba[i - c] = (byte)Math.Min(255, (rgba[i - c] * 255 + alpha / 2) / alpha);
            }
        }
        return new PdfRgbaImage(image.Width, image.Height, rgba);
    }

    private static bool Inverts(double[]? decode) => decode is { Length: >= 8 } && decode.Chunk(2).Take(4).All(pair => pair is [1, 0]);

    // The Adobe marker (APP14) tells a codec that the stored inks are inverted.
    private static bool HasAdobeMarker(byte[] jpeg)
    {
        int p = 2;
        while (p + 4 <= jpeg.Length && jpeg[p] == 0xFF && jpeg[p + 1] != 0xDA)
        {
            int length = jpeg[p + 2] << 8 | jpeg[p + 3];
            if (jpeg[p + 1] == 0xEE && length >= 7 && p + 9 <= jpeg.Length && jpeg[p + 4] == 'A' && jpeg[p + 5] == 'd') return true;
            p += 2 + length;
        }
        return false;
    }

    // A codec shows an Adobe-marked CMYK JPEG the way a JPEG file looks and an unmarked one as stored.
    // A page shows the stored inks after /Decode, so the two differ when the marker and a reversing
    // /Decode disagree; the RGB inverse stands in for the ink inverse, which RGB cannot give back.
    private PdfRgbaImage CmykView(PdfDictionary dictionary, PdfRgbaImage pixels, SampleColorSpace space, bool marked)
    {
        var decode = PdfFunction.Numbers(dictionary["Decode"], document.Resolve);
        var rgba = (byte[])pixels.Rgba.Clone();
        if (marked != Inverts(decode))
        {
            for (int i = 0; i < rgba.Length; i++)
            {
                if (i % 4 != 3) rgba[i] = (byte)(255 - rgba[i]);
            }
        }
        if (PdfFunction.Numbers(dictionary["Mask"], document.Resolve) is { Length: >= 8 } key) Key(rgba, key, decode, space);
        return new PdfRgbaImage(pixels.Width, pixels.Height, rgba);
    }

    // The colour key (ISO 32000-1 8.9.6.4) is matched against the RGB of the corners of its ink range.
    private static void Key(byte[] rgba, double[] key, double[]? decode, SampleColorSpace space)
    {
        Span<double> ink = stackalloc double[4];
        Span<byte> rgb = stackalloc byte[3];
        int[] low = [255, 255, 255], high = [0, 0, 0];
        bool decoded = decode is { Length: >= 8 };
        for (int corner = 0; corner < 16; corner++)
        {
            for (int j = 0; j < 4; j++)
            {
                double from = decoded ? decode![2 * j] : space.Min(j), to = decoded ? decode![2 * j + 1] : space.Max(j);
                ink[j] = from + key[2 * j + (corner >> j & 1)] * (to - from) / 255;
            }
            space.ToRgb(ink, rgb);
            for (int c = 0; c < 3; c++)
            {
                low[c] = Math.Min(low[c], rgb[c]);
                high[c] = Math.Max(high[c], rgb[c]);
            }
        }
        for (int i = 0; i < rgba.Length; i += 4)
        {
            bool inside = true;
            for (int c = 0; c < 3; c++) inside &= rgba[i + c] >= low[c] && rgba[i + c] <= high[c];
            if (inside) rgba[i + 3] = 0;
        }
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
            // A soft mask overrides /Mask (ISO 32000-1 8.9.6.5), so a /Mask stream is never read.
            plain.Remove("Mask");
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

    // A coded mask is charged for what the codec returns; an unreadable size is refused later and costs
    // nothing. The size is read as the samples code reads it, /W and /H included.
    private void ChargeMask(PdfStream mask)
    {
        if (IsCoded(mask)) return;
        var d = mask.Dictionary;
        long width = PdfFilters.Int(document.Resolve(d["Width"] ?? d["W"]), 0), height = PdfFilters.Int(document.Resolve(d["Height"] ?? d["H"]), 0);
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
