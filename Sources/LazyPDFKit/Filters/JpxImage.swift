import Foundation

// Twin of windows/LazyPDF.Core/Filters/JpxImage.cs: what a JPEG 2000 image's codec output stands for. The codec knows
// nothing of the PDF dictionary: it gives sRGB or RGBA, with a palette already applied. Its pixels are used for an image
// whose /ColorSpace is absent or a device, Cal or ICC based space of one, three or four components; for any other space
// (Indexed, Separation, DeviceN, Lab) the image is one that cannot be decoded.

enum JpxImage {
    /// True when the codec's pixels show the image as its colour space would.
    static func readable(_ document: PdfDocument, _ dictionary: PdfDictionary) -> Bool {
        guard let space = document.resolve(dictionary["ColorSpace"]), !(space is PdfNull) else { return true }
        let family = ImageKit.describe(document, dictionary["ColorSpace"]).family
        return family == .gray || family == .rgb || family == .cmyk
    }

    /// The component count of the colour space for the codec's hint; 0 when there is none.
    static func components(_ document: PdfDocument, _ dictionary: PdfDictionary) -> Int {
        guard let space = document.resolve(dictionary["ColorSpace"]), !(space is PdfNull) else { return 0 }
        return ImageKit.describe(document, dictionary["ColorSpace"]).components
    }

    /// The /SMaskInData of the image: 0 leaves the codestream's alpha out, 1 takes it as straight alpha, 2 as premultiplied.
    static func maskInData(_ document: PdfDocument, _ dictionary: PdfDictionary) -> Int {
        document.integer(dictionary, "SMaskInData") ?? 0
    }

    /// The pixels with their alpha as /SMaskInData says (ISO 32000-1 Table 89): dropped for 0, kept for 1, and for 2 taken out of the colour.
    static func alpha(_ image: PdfRgbaImage, _ mode: Int) -> PdfRgbaImage {
        if mode == 1 { return image }
        var rgba = image.rgba
        var i = 3
        while i < rgba.count {
            let alpha = Int(rgba[i])
            if mode < 1 {
                rgba[i] = 255
            } else if alpha > 0 && alpha < 255 {
                for c in 1...3 { rgba[i - c] = UInt8(truncatingIfNeeded: min(255, (Int(rgba[i - c]) * 255 + alpha / 2) / alpha)) }
            }
            i += 4
        }
        return PdfRgbaImage(image.width, image.height, rgba, dpiX: image.dpiX, dpiY: image.dpiY)
    }
}
