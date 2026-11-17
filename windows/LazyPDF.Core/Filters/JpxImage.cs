namespace LazyPDF.Core;

/// <summary>
/// What a JPEG 2000 image's codec output stands for. The codec knows nothing of the PDF dictionary: it gives sRGB or RGBA, with a
/// palette already applied. Its pixels are used for an image whose /ColorSpace is absent or a device, Cal or ICC based space of
/// one, three or four components; for any other space (Indexed, Separation, DeviceN, Lab) the image is one that cannot be decoded.
/// </summary>
internal static class JpxImage
{
    /// <summary>True when the codec's pixels show the image as its colour space would.</summary>
    public static bool Readable(PdfDocument document, PdfDictionary dictionary)
    {
        if (document.Resolve(dictionary["ColorSpace"]) is null or PdfNull) return true;
        return ImageKit.Describe(document, dictionary["ColorSpace"]).Family is ImageFamily.Gray or ImageFamily.Rgb or ImageFamily.Cmyk;
    }

    /// <summary>The component count of the colour space for the codec's hint; 0 when there is none.</summary>
    public static int Components(PdfDocument document, PdfDictionary dictionary) =>
        document.Resolve(dictionary["ColorSpace"]) is null or PdfNull ? 0 : ImageKit.Describe(document, dictionary["ColorSpace"]).Components;

    /// <summary>The /SMaskInData of the image: 0 leaves the codestream's alpha out, 1 takes it as straight alpha, 2 as premultiplied.</summary>
    public static long MaskInData(PdfDocument document, PdfDictionary dictionary) => document.Integer(dictionary, "SMaskInData") ?? 0;

    /// <summary>The pixels with their alpha as /SMaskInData says (ISO 32000-1 Table 89): dropped for 0, kept for 1, and for 2 taken out of the colour.</summary>
    public static PdfRgbaImage Alpha(PdfRgbaImage image, long mode)
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
        return new PdfRgbaImage(image.Width, image.Height, rgba, image.DpiX, image.DpiY);
    }
}
