import Foundation

// Twin of windows/LazyPDF.Core/Filters/DctImage.cs: what a DCT image's codec output stands for. As for JPEG 2000 (JpxImage) the
// codec's pixels are used for an image whose /ColorSpace is absent or a device, Cal or ICC based space of one, three or four
// components; any other space (Indexed, Separation, DeviceN, Lab) has samples the pixels do not show, so the image is one that
// cannot be decoded.

enum DctImage {
    /// True when the colour space is one the codec's pixels can stand for.
    static func readable(_ document: PdfDocument, _ dictionary: PdfDictionary) -> Bool {
        guard let space = document.resolve(dictionary["ColorSpace"]), !(space is PdfNull) else { return true }
        let family = ImageKit.describe(document, dictionary["ColorSpace"]).family
        return family == .gray || family == .rgb || family == .cmyk
    }

    /// True when the codec's pixels of a CMYK picture are what the page shows. A codec shows an Adobe-marked file the way a JPEG
    /// file looks and an unmarked one as stored, while the page shows the stored inks after /Decode: the two agree when the marker
    /// and a reversing /Decode agree, and are inverses of each other otherwise.
    static func cmykAsShown(_ document: PdfDocument, _ dictionary: PdfDictionary, _ jpeg: [UInt8]) -> Bool {
        let decode = PdfFunction.numbers(dictionary["Decode"], { document.resolve($0) })
        let marked = ExportImageMerge.hasAdobeMarker(jpeg)
        if ExportImageMerge.inverts(decode) { return marked }
        guard let decode else { return !marked }
        return !marked && ImageKit.defaultDecode(document, dictionary, decode)
    }
}
