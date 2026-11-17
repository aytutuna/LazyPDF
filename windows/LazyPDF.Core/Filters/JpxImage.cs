namespace LazyPDF.Core;

/// <summary>
/// What a JPEG 2000 image's codec output stands for. The codec knows nothing of the PDF dictionary: it gives sRGB or RGBA, with a
/// palette already applied and always as straight alpha. Its pixels are used for an image whose /ColorSpace is absent or a device,
/// Cal or ICC based space of one, three or four components; for any other space (Indexed, Separation, DeviceN, Lab) the image
/// is one that cannot be decoded, and neither is one whose /SMaskInData is 2 (premultiplied colour).
/// </summary>
internal static class JpxImage
{
    /// <summary>True when the codec's pixels show the image as its colour space and /SMaskInData would.</summary>
    public static bool Readable(PdfDocument document, PdfDictionary dictionary)
    {
        if (MaskInData(document, dictionary) == 2) return false;
        if (document.Resolve(dictionary["ColorSpace"]) is null or PdfNull) return true;
        return ImageKit.Describe(document, dictionary["ColorSpace"]).Family is ImageFamily.Gray or ImageFamily.Rgb or ImageFamily.Cmyk;
    }

    /// <summary>The component count of the colour space for the codec's hint; 0 when there is none.</summary>
    public static int Components(PdfDocument document, PdfDictionary dictionary) =>
        document.Resolve(dictionary["ColorSpace"]) is null or PdfNull ? 0 : ImageKit.Describe(document, dictionary["ColorSpace"]).Components;

    /// <summary>The /SMaskInData of the image: 0 leaves the codestream's alpha out, 1 takes it as straight alpha, 2 as premultiplied.</summary>
    public static long MaskInData(PdfDocument document, PdfDictionary dictionary) => document.Integer(dictionary, "SMaskInData") ?? 0;

    /// <summary>The pixels with their alpha as /SMaskInData says (ISO 32000-1 Table 89): dropped for 0, kept for 1. The codec's alpha is straight already.</summary>
    public static PdfRgbaImage Alpha(PdfRgbaImage image, long mode)
    {
        if (mode > 0) return image;
        var rgba = (byte[])image.Rgba.Clone();
        for (int i = 3; i < rgba.Length; i += 4) rgba[i] = 255;
        return new PdfRgbaImage(image.Width, image.Height, rgba, image.DpiX, image.DpiY);
    }

    /// <summary>
    /// True when no pixel has any transparency. With /SMaskInData 0 the alpha is dropped, which only shows the picture as the codecs
    /// give it when it has none: ImageIO returns colour premultiplied, so a pixel with alpha 0 has lost its colour there.
    /// </summary>
    public static bool Opaque(PdfRgbaImage image)
    {
        for (int i = 3; i < image.Rgba.Length; i += 4)
        {
            if (image.Rgba[i] != 255) return false;
        }
        return true;
    }
}
