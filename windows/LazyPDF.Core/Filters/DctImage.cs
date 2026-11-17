namespace LazyPDF.Core;

/// <summary>
/// What a DCT image's codec output stands for. As for JPEG 2000 (<see cref="JpxImage"/>) the codec's pixels are used for an image
/// whose /ColorSpace is absent or a device, Cal or ICC based space of one, three or four components; any other space (Indexed,
/// Separation, DeviceN, Lab) has samples the pixels do not show, so the image is one that cannot be decoded.
/// </summary>
internal static class DctImage
{
    /// <summary>True when the colour space is one the codec's pixels can stand for.</summary>
    public static bool Readable(PdfDocument document, PdfDictionary dictionary)
    {
        if (document.Resolve(dictionary["ColorSpace"]) is null or PdfNull) return true;
        return ImageKit.Describe(document, dictionary["ColorSpace"]).Family is ImageFamily.Gray or ImageFamily.Rgb or ImageFamily.Cmyk;
    }

    /// <summary>
    /// True when the codec's pixels of a CMYK picture are what the page shows. A codec shows an Adobe-marked file the way a JPEG
    /// file looks and an unmarked one as stored, while the page shows the stored inks after /Decode: the two agree when the marker
    /// and a reversing /Decode agree, and are inverses of each other otherwise.
    /// </summary>
    public static bool CmykAsShown(PdfDocument document, PdfDictionary dictionary, byte[] jpeg)
    {
        var decode = PdfFunction.Numbers(dictionary["Decode"], document.Resolve);
        bool marked = ExportImageMerge.HasAdobeMarker(jpeg);
        if (ExportImageMerge.Inverts(decode)) return marked;
        return !marked && (decode is null || ImageKit.DefaultDecode(document, dictionary, decode));
    }
}
