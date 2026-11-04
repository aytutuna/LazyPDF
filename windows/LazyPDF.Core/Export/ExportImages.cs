namespace LazyPDF.Core;

/// <summary>
/// Turns the images a page paints into files. A JPEG with nothing to merge goes out as its own
/// bytes; the rest are decoded and written as PNG, an /SMask becoming alpha. Results are kept per
/// image object, so a logo on every page is decoded once.
/// </summary>
internal sealed class ExportImages(PdfDocument document, IImageCodec? codec)
{
    // Past this many pixels an image is left out rather than decoded (rule 4).
    private const long MaxPixels = 1L << 26;
    private const long MaxTotalBytes = 1L << 29;

    private readonly Dictionary<PdfStream, ExportImage?> _cache = new(ReferenceEqualityComparer.Instance);
    private long _total;

    public ExportImage? Get(ImageInfo info)
    {
        if (info.Stream is { } stream)
        {
            if (_cache.TryGetValue(stream, out var cached)) return cached;
            var made = Make(info.Dictionary, document.RawData(stream), stream);
            _cache[stream] = made;
            return made;
        }
        return info.Inline is { } inline ? Make(info.Dictionary, inline.Data, null) : null;
    }

    private ExportImage? Make(PdfDictionary dictionary, byte[] raw, PdfStream? stream)
    {
        try
        {
            if (_total > MaxTotalBytes) return null;
            long width = document.Integer(dictionary, "Width") ?? 0, height = document.Integer(dictionary, "Height") ?? 0;
            if (width < 1 || height < 1 || width * height > MaxPixels) return null;

            PdfObject? filter, parameters;
            if (stream is not null) (filter, parameters, _) = document.DecodeSpec(stream);
            else (filter, parameters) = (dictionary["Filter"], dictionary["DecodeParms"]);
            var decoded = PdfFilters.DecodeToCodec(raw, filter, parameters);

            ExportImage? image;
            if (decoded.Codec is null)
            {
                var rgba = PdfImageSamples.ToRgba(dictionary, decoded.Data, document.Resolve, document.Data);
                image = Png(rgba);
            }
            else if (decoded.Codec == "DCTDecode" && !NeedsMerge(dictionary))
            {
                image = new ExportImage(decoded.Data, true, (int)width, (int)height);
            }
            else if (codec?.Decode(decoded.Data, decoded.Codec) is { } pixels)
            {
                image = Png(WithMask(dictionary, pixels));
            }
            else
            {
                image = decoded.Codec == "DCTDecode" ? new ExportImage(decoded.Data, true, (int)width, (int)height) : null;
            }
            if (image is not null) _total += image.Data.Length;
            return image;
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    private static ExportImage Png(PdfRgbaImage rgba) => new(PngWriter.Encode(rgba), false, rgba.Width, rgba.Height);

    private bool NeedsMerge(PdfDictionary dictionary) =>
        document.Resolve(dictionary["SMask"]) is not null || document.Resolve(dictionary["Mask"]) is not null
        || document.Bool(dictionary, "ImageMask") == true || document.Array(dictionary, "Decode") is not null;

    // A decoded picture gets the alpha of its soft mask, sampled nearest when the sizes differ.
    private PdfRgbaImage WithMask(PdfDictionary dictionary, PdfRgbaImage pixels)
    {
        if (document.Stream(dictionary, "SMask") is not { } mask) return pixels;
        var maskImage = PdfImageSamples.ToRgba(mask.Dictionary, document.Data(mask), document.Resolve, document.Data);
        var rgba = (byte[])pixels.Rgba.Clone();
        for (int y = 0; y < pixels.Height; y++)
        {
            int my = (int)((long)y * maskImage.Height / pixels.Height);
            for (int x = 0; x < pixels.Width; x++)
            {
                int mx = (int)((long)x * maskImage.Width / pixels.Width);
                rgba[(y * pixels.Width + x) * 4 + 3] = maskImage.Rgba[(my * maskImage.Width + mx) * 4];
            }
        }
        return new PdfRgbaImage(pixels.Width, pixels.Height, rgba);
    }
}
