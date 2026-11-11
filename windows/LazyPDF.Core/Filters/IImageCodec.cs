namespace LazyPDF.Core;

/// <summary>The image codecs Core leaves to the system (WIC on Windows, ImageIO on Apple).</summary>
public interface IImageCodec
{
    /// <summary>
    /// Pixels of a stream's data under <paramref name="codec"/>: DCTDecode, JPXDecode or JBIG2Decode.
    /// Null when the system cannot read it.
    /// </summary>
    PdfRgbaImage? Decode(byte[] data, string codec);

    /// <summary>Every frame of a picture file (JPEG, PNG, TIFF, BMP, GIF, HEIC), or null for anything else. A frame carries the resolution the file stores, in dots per inch.</summary>
    IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file);

    /// <summary>A JPEG of <paramref name="image"/>; <paramref name="quality"/> runs from 1 to 100.</summary>
    byte[] EncodeJpeg(PdfRgbaImage image, int quality);
}
