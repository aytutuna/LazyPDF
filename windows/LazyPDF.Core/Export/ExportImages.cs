using System.Security.Cryptography;

namespace LazyPDF.Core;

/// <summary>
/// Turns the images a page paints into files. A JPEG that a JPEG file shows as the page does goes
/// out as its own bytes; the rest are decoded and written as PNG with their masks, /Decode and
/// colour space applied. Results are kept per image object, and per picture for inline images, so
/// a logo on every page is decoded once.
/// </summary>
internal sealed class ExportImages(PdfDocument document, IImageCodec? codec, CancellationToken cancel = default, long pixelBudget = 1L << 32)
{
    // Past this many pixels an image is left out rather than decoded (rule 4).
    private const long MaxPixels = 1L << 26;
    private const long MaxTotalBytes = 1L << 29;

    private readonly ExportImageMerge _merge = new(document, codec, pixelBudget);
    private readonly Dictionary<(PdfStream, int), ExportImage?> _streams = [];
    private readonly Dictionary<(string, int), ExportImage?> _inline = [];
    private long _total;

    /// <summary>
    /// The picture for <paramref name="info"/>. <paramref name="orientation"/> (1 to 8, as in Exif)
    /// turns its pixels to the way the page shows them; a JPEG kept as its own bytes cannot be turned.
    /// </summary>
    public ExportImage? Get(ImageInfo info, int orientation = 1)
    {
        ExportImage? image;
        if (info.Stream is { } stream)
        {
            if (!_streams.TryGetValue((stream, orientation), out image))
                _streams[(stream, orientation)] = image = Make(info.Dictionary, document.RawData(stream), stream, orientation);
            return image;
        }
        if (info.Inline is not { } inline) return null;
        string text;
        try
        {
            text = info.Dictionary.ToString();
        }
        catch (InvalidOperationException)
        {
            // A stream cannot be written inline; a colour space that resolves to one is damage.
            return null;
        }
        var key = ($"{text}|{Convert.ToBase64String(SHA256.HashData(inline.Data))}", orientation);
        if (!_inline.TryGetValue(key, out image)) _inline[key] = image = Make(info.Dictionary, inline.Data, null, orientation);
        return image;
    }

    private ExportImage? Make(PdfDictionary dictionary, byte[] raw, PdfStream? stream, int orientation)
    {
        try
        {
            cancel.ThrowIfCancellationRequested();
            long width = document.Integer(dictionary, "Width") ?? 0, height = document.Integer(dictionary, "Height") ?? 0;
            if (width < 1 || height < 1 || width * height > MaxPixels) return null;

            PdfObject? filter, parameters;
            if (stream is not null) (filter, parameters, _) = document.DecodeSpec(stream);
            else (filter, parameters) = (dictionary["Filter"], dictionary["DecodeParms"]);
            var decoded = PdfFilters.DecodeToCodec(raw, filter, parameters);

            ExportImage Jpeg() => new(decoded.Data, true, (int)width, (int)height);
            if (decoded.Codec == "DCTDecode" && orientation == 1 && _merge.ShowsAsFile(dictionary)) return Keep(Jpeg());

            // Past a limit a JPEG is still kept as its bytes: they are in hand and cost nothing to decode.
            PdfRgbaImage? pixels = null;
            try
            {
                if (_total > MaxTotalBytes) throw new PdfReadException(PdfReadProblem.Unsupported, ExportText.TooLarge);
                if (decoded.Codec is null)
                {
                    _merge.Charge(width * height);
                    pixels = _merge.FromSamples(dictionary, decoded.Data);
                }
                else if (codec is not null)
                {
                    _merge.Charge(0);
                    if (codec.Decode(decoded.Data, decoded.Codec) is { } coded && (long)coded.Width * coded.Height <= MaxPixels)
                    {
                        _merge.Charge((long)coded.Width * coded.Height);
                        pixels = _merge.FromPixels(dictionary, coded, decoded.Codec);
                    }
                }
            }
            catch (PdfReadException) when (decoded.Codec == "DCTDecode")
            {
            }
            if (pixels is null) return decoded.Codec == "DCTDecode" ? Keep(Jpeg()) : null;
            pixels = ExportImageTurn.Apply(pixels, orientation);
            return Keep(new ExportImage(PngWriter.Encode(pixels), false, pixels.Width, pixels.Height));
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    private ExportImage Keep(ExportImage image)
    {
        _total += image.Data.Length;
        return image;
    }
}
