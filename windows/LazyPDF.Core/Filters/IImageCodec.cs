namespace LazyPDF.Core;

/// <summary>The image codecs Core leaves to the system (WIC on Windows, ImageIO on Apple).</summary>
public interface IImageCodec
{
    /// <summary>
    /// Pixels of a stream's data under <paramref name="codec"/>: DCTDecode or JPXDecode.
    /// Null when the system cannot read it. <paramref name="components"/> is the component count of the image's PDF colour space, or 0
    /// when there is none or it is not known; a codec that has to guess what the data holds (JPEG 2000 without a colour box, say) takes
    /// its hint from it. The pixels are sRGB or RGBA whatever the PDF says (see <see cref="JpxImage"/> for what callers may use).
    /// </summary>
    PdfRgbaImage? Decode(byte[] data, string codec, int components = 0);

    /// <summary>Every frame of a picture file (JPEG, PNG, TIFF, BMP, GIF, HEIC), or null for anything else. A frame carries the resolution the file stores, in dots per inch. A frame with too many pixels comes back as a placeholder with its size and no pixels (`TooBig`).</summary>
    IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file);

    /// <summary>A JPEG of <paramref name="image"/>; <paramref name="quality"/> runs from 1 to 100.</summary>
    byte[] EncodeJpeg(PdfRgbaImage image, int quality);
}
