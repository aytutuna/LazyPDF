namespace LazyPDF.Core;

/// <summary>An image as straight (not premultiplied) RGBA8, rows top to bottom.</summary>
public sealed record PdfRgbaImage(int Width, int Height, byte[] Rgba, double DpiX = 0, double DpiY = 0)
{
    /// <summary>A frame too big to decode: it keeps its size and has no pixels.</summary>
    public bool TooBig => Rgba.Length == 0 && Width > 0 && Height > 0;
}

/// <summary>Image XObject samples (ISO 32000-1 8.9) turned into RGBA8.</summary>
public static class PdfImageSamples
{
    /// <summary>The most pixels one image may have; a bigger one is <see cref="PdfReadProblem.Unsupported"/>.</summary>
    public const long MaxPixels = 1L << 27;

    private const long MaxRowSamples = 1L << 26;

    /// <summary>
    /// <paramref name="samples"/> are the image's data with every filter undone, an image codec's
    /// included. <paramref name="resolve"/> follows references; <paramref name="decodeStream"/> gives a
    /// stream's data with its filters undone (lookup tables, function samples) and, for a mask
    /// image, the decoded samples. Missing samples read as zero. An image mask comes out black where
    /// it paints, transparent elsewhere. Handles inline image keys (/W, /H, /BPC, /CS, /IM, /D) too.
    /// </summary>
    public static PdfRgbaImage ToRgba(PdfDictionary image, byte[] samples, Func<PdfObject?, PdfObject?> resolve, Func<PdfStream, byte[]> decodeStream)
    {
        var (width, height) = Size(image, resolve);
        bool isMask = resolve(Get(image, "ImageMask", "IM")) is PdfBoolean { Value: true };
        int bpc = isMask ? 1 : PdfFilters.Int(resolve(Get(image, "BitsPerComponent", "BPC")), 8);
        if (bpc is not (1 or 2 or 4 or 8 or 16)) throw PdfReadException.Damaged($"An image with {bpc} bits per component.");
        var decode = PdfFunction.Numbers(Get(image, "Decode", "D"), resolve);

        if (isMask)
        {
            var rgba = new byte[width * height * 4];
            var gray = Plane(width, height, bpc, decode, samples);
            for (int i = 0; i < gray.Length; i++) rgba[i * 4 + 3] = gray[i] < 128 ? (byte)255 : (byte)0;
            return new PdfRgbaImage(width, height, rgba);
        }

        var space = ColorSpaceOf(image, samples, width, height, bpc, resolve, decodeStream);
        if ((long)width * space.Components > MaxRowSamples) throw new PdfReadException(PdfReadProblem.Unsupported, "An image row is too wide.");
        var pixels = new byte[width * height * 4];
        ConvertPixels(pixels, width, height, bpc, space, decode, ColorKey(image, space.Components, resolve), samples);

        if (resolve(image["SMask"]) is PdfStream soft) ApplyMask(pixels, width, height, soft, stencil: false, resolve, decodeStream);
        else if (resolve(image["Mask"]) is PdfStream hard) ApplyMask(pixels, width, height, hard, stencil: true, resolve, decodeStream);
        return new PdfRgbaImage(width, height, pixels);
    }

    private static PdfObject? Get(PdfDictionary d, string key, string abbreviation) => d[key] ?? d[abbreviation];

    private static (int Width, int Height) Size(PdfDictionary image, Func<PdfObject?, PdfObject?> resolve)
    {
        int width = PdfFilters.Int(resolve(Get(image, "Width", "W")), 0);
        int height = PdfFilters.Int(resolve(Get(image, "Height", "H")), 0);
        if (width < 1 || height < 1) throw PdfReadException.Damaged("An image has no size.");
        if ((long)width * height > MaxPixels || width > MaxRowSamples) throw new PdfReadException(PdfReadProblem.Unsupported, "An image has too many pixels.");
        return (width, height);
    }

    private static SampleColorSpace ColorSpaceOf(PdfDictionary image, byte[] samples, int width, int height, int bpc,
                                                  Func<PdfObject?, PdfObject?> resolve, Func<PdfStream, byte[]> decodeStream)
    {
        if (resolve(Get(image, "ColorSpace", "CS")) is { } declared and not PdfNull)
            return SampleColorSpace.Parse(declared, resolve, decodeStream);
        // A JPEG 2000 image may leave the space to the codec; the sample count says which it is.
        long perPixel = samples.Length * 8L / ((long)width * height * bpc);
        return perPixel switch
        {
            1 => new SampleColorSpace.Gray(),
            3 => new SampleColorSpace.Rgb(),
            4 => new SampleColorSpace.Cmyk(),
            _ => throw PdfReadException.Damaged("An image has no /ColorSpace."),
        };
    }

    private static int[]? ColorKey(PdfDictionary image, int components, Func<PdfObject?, PdfObject?> resolve)
    {
        var numbers = PdfFunction.Numbers(image["Mask"], resolve);
        return numbers is null || numbers.Length < components * 2 ? null : numbers.Select(n => (int)n).ToArray();
    }

    private static void ConvertPixels(byte[] rgba, int width, int height, int bpc, SampleColorSpace space, double[]? decode, int[]? key, byte[] samples)
    {
        int n = space.Components;
        int maxRaw = (1 << bpc) - 1;
        var minimum = new double[n];
        var scale = new double[n];
        bool plain = true;
        for (int j = 0; j < n; j++)
        {
            double low = space is SampleColorSpace.Indexed ? 0 : space.Min(j);
            double high = space is SampleColorSpace.Indexed ? maxRaw : space.Max(j);
            if (decode is not null && decode.Length >= 2 * n)
            {
                plain &= decode[2 * j] == low && decode[2 * j + 1] == high;
                low = decode[2 * j];
                high = decode[2 * j + 1];
            }
            minimum[j] = low;
            scale[j] = (high - low) / maxRaw;
        }

        byte[]? lut = null;
        if (n == 1 && bpc <= 8)
        {
            lut = new byte[(maxRaw + 1) * 3];
            Span<double> c = stackalloc double[1];
            for (int v = 0; v <= maxRaw; v++)
            {
                c[0] = minimum[0] + v * scale[0];
                space.ToRgb(c, lut.AsSpan(v * 3, 3));
            }
        }
        bool direct = plain && bpc == 8 && space is SampleColorSpace.Rgb;

        int rowBytes = (int)(((long)width * n * bpc + 7) / 8);
        var scratch = new byte[rowBytes];
        var raw = new int[width * n];
        var comps = new double[n];
        var last = new int[n];
        var current = new byte[3];
        bool haveLast = false;
        for (int y = 0; y < height; y++)
        {
            Unpack(RowOf(samples, y, rowBytes, scratch), bpc, raw);
            int o = y * width * 4;
            for (int x = 0; x < width; x++, o += 4)
            {
                var px = raw.AsSpan(x * n, n);
                if (lut is not null)
                {
                    lut.AsSpan(px[0] * 3, 3).CopyTo(rgba.AsSpan(o));
                }
                else if (direct)
                {
                    rgba[o] = (byte)px[0];
                    rgba[o + 1] = (byte)px[1];
                    rgba[o + 2] = (byte)px[2];
                }
                else
                {
                    if (!haveLast || !px.SequenceEqual(last))
                    {
                        for (int j = 0; j < n; j++) comps[j] = minimum[j] + px[j] * scale[j];
                        space.ToRgb(comps, current);
                        px.CopyTo(last);
                        haveLast = true;
                    }
                    current.CopyTo(rgba.AsSpan(o));
                }
                rgba[o + 3] = key is not null && InKey(px, key) ? (byte)0 : (byte)255;
            }
        }
    }

    private static bool InKey(ReadOnlySpan<int> pixel, int[] key)
    {
        for (int j = 0; j < pixel.Length; j++)
        {
            if (pixel[j] < key[2 * j] || pixel[j] > key[2 * j + 1]) return false;
        }
        return true;
    }

    private static ReadOnlySpan<byte> RowOf(byte[] samples, int y, int rowBytes, byte[] scratch)
    {
        long start = (long)y * rowBytes;
        if (start + rowBytes <= samples.Length) return samples.AsSpan((int)start, rowBytes);
        Array.Clear(scratch);
        if (start < samples.Length) samples.AsSpan((int)start).CopyTo(scratch);
        return scratch;
    }

    private static void Unpack(ReadOnlySpan<byte> row, int bpc, Span<int> raw)
    {
        switch (bpc)
        {
            case 8:
                for (int i = 0; i < raw.Length; i++) raw[i] = row[i];
                break;
            case 16:
                for (int i = 0; i < raw.Length; i++) raw[i] = row[2 * i] << 8 | row[2 * i + 1];
                break;
            default:
                int mask = (1 << bpc) - 1;
                for (int i = 0; i < raw.Length; i++)
                {
                    int bit = i * bpc;
                    raw[i] = row[bit >> 3] >> (8 - bpc - (bit & 7)) & mask;
                }
                break;
        }
    }

    /// <summary>One-component samples as grey bytes, 0 to 255, through /Decode.</summary>
    private static byte[] Plane(int width, int height, int bpc, double[]? decode, byte[] samples)
    {
        double low = decode is { Length: >= 2 } ? decode[0] : 0;
        double high = decode is { Length: >= 2 } ? decode[1] : 1;
        int maxRaw = (1 << bpc) - 1;
        int rowBytes = (int)(((long)width * bpc + 7) / 8);
        var scratch = new byte[rowBytes];
        var raw = new int[width];
        var gray = new byte[width * height];
        for (int y = 0; y < height; y++)
        {
            Unpack(RowOf(samples, y, rowBytes, scratch), bpc, raw);
            for (int x = 0; x < width; x++) gray[y * width + x] = SampleColorSpace.Byte(low + raw[x] * (high - low) / maxRaw);
        }
        return gray;
    }

    private static void ApplyMask(byte[] rgba, int width, int height, PdfStream mask, bool stencil,
                                  Func<PdfObject?, PdfObject?> resolve, Func<PdfStream, byte[]> decodeStream)
    {
        var dictionary = mask.Dictionary;
        var (maskWidth, maskHeight) = Size(dictionary, resolve);
        bool imageMask = resolve(Get(dictionary, "ImageMask", "IM")) is PdfBoolean { Value: true };
        int bpc = stencil || imageMask ? 1 : PdfFilters.Int(resolve(Get(dictionary, "BitsPerComponent", "BPC")), 8);
        if (bpc is not (1 or 2 or 4 or 8 or 16)) throw PdfReadException.Damaged($"A mask with {bpc} bits per component.");
        var gray = Plane(maskWidth, maskHeight, bpc, PdfFunction.Numbers(Get(dictionary, "Decode", "D"), resolve), decodeStream(mask));
        for (int y = 0; y < height; y++)
        {
            int row = (int)((long)y * maskHeight / height) * maskWidth;
            for (int x = 0; x < width; x++)
            {
                byte value = gray[row + (int)((long)x * maskWidth / width)];
                rgba[(y * width + x) * 4 + 3] = stencil ? (value < 128 ? (byte)255 : (byte)0) : value;
            }
        }
    }
}
