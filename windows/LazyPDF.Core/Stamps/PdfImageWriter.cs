namespace LazyPDF.Core;

/// <summary>An image XObject in a document with its size in pixels.</summary>
public sealed record PdfImage(PdfReference Reference, int Width, int Height);

/// <summary>
/// Adds images to a document for stamps, signatures and pictures placed on a page. JPEG bytes go in
/// as they are (DCTDecode), pixels are deflated with an /SMask when any of them is not opaque.
/// </summary>
public static class PdfImageWriter
{
    /// <summary>The JPEG embedded as it is; null when its header cannot be read or it has an unusual number of components.</summary>
    public static PdfImage? AddJpeg(PdfDocument document, byte[] jpeg)
    {
        if (!TryReadJpegHeader(jpeg, out int width, out int height, out int components) || components is not (1 or 3 or 4)) return null;
        return ContentImages.AddJpeg(document, jpeg) is { } reference ? new PdfImage(reference, width, height) : null;
    }

    /// <summary><paramref name="rgba"/> is straight RGBA8, top row first.</summary>
    /// <exception cref="ArgumentException">The size is not positive or does not fit the data.</exception>
    /// <exception cref="InvalidOperationException">The picture has more pixels than an image may (<see cref="StampsText.PictureTooLarge"/>).</exception>
    public static PdfImage AddRgba(PdfDocument document, int width, int height, byte[] rgba)
    {
        // A picture the user picked can be this big; it is not a caller's mistake.
        if (width >= 1 && height >= 1 && (long)width * height > PdfImageSamples.MaxPixels) throw new InvalidOperationException(StampsText.PictureTooLarge);
        return new(ContentImages.AddRgba(document, width, height, rgba), width, height);
    }

    // From Lazy Scan's PdfBuilder.cs: the frame size and component count
    // of a JPEG from its start-of-frame segment, walking the markers by their lengths.
    internal static bool TryReadJpegHeader(ReadOnlySpan<byte> jpeg, out int width, out int height,
                                           out int components)
    {
        width = 0;
        height = 0;
        components = 0;
        if (jpeg.Length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return false;
        int pos = 2;
        while (pos < jpeg.Length)
        {
            if (jpeg[pos] != 0xFF) return false;
            // Any number of 0xFF fill bytes may precede a marker code.
            while (pos < jpeg.Length && jpeg[pos] == 0xFF) pos++;
            if (pos >= jpeg.Length) return false;
            byte marker = jpeg[pos++];

            // Standalone markers carry no length: TEM, RSTn, SOI.
            if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) continue;
            // Scan data or the end of the image before any frame header: no size to be had.
            if (marker == 0xDA || marker == 0xD9 || marker == 0x00) return false;

            if (pos + 2 > jpeg.Length) return false;
            int length = (jpeg[pos] << 8) | jpeg[pos + 1];
            if (length < 2 || pos + length > jpeg.Length) return false;

            // SOF0...SOF15, except DHT (C4), JPG (C8) and DAC (CC), which share the range.
            bool isFrame = marker >= 0xC0 && marker <= 0xCF &&
                           marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
            if (isFrame)
            {
                // Length(2) precision(1) height(2) width(2) components(1) ...
                if (length < 8) return false;
                height = (jpeg[pos + 3] << 8) | jpeg[pos + 4];
                width = (jpeg[pos + 5] << 8) | jpeg[pos + 6];
                components = jpeg[pos + 7];
                // Height 0 means "defined later by DNL"; treat it as unknown.
                return width > 0 && height > 0 && components > 0;
            }
            pos += length;
        }
        return false;
    }
}
