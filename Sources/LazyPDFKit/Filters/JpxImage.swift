import Foundation

// Twin of windows/LazyPDF.Core/Filters/JpxImage.cs: what a JPEG 2000 image's codec output stands for. The codec knows
// nothing of the PDF dictionary: it gives sRGB or RGBA, with a palette already applied and always as straight alpha. Its
// pixels are used for an image whose /ColorSpace is absent or a device, Cal or ICC based space of one, three or four
// components; for any other space (Indexed, Separation, DeviceN, Lab) the image is one that cannot be decoded, and neither
// is one whose /SMaskInData is 2 (premultiplied colour).

enum JpxImage {
    /// True when the codec's pixels show the image as its colour space and /SMaskInData would.
    static func readable(_ document: PdfDocument, _ dictionary: PdfDictionary) -> Bool {
        if maskInData(document, dictionary) == 2 { return false }
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

    /// The pixels with their alpha as /SMaskInData says (ISO 32000-1 Table 89): dropped for 0, kept for 1. The codec's alpha is straight already.
    static func alpha(_ image: PdfRgbaImage, _ mode: Int) -> PdfRgbaImage {
        if mode > 0 { return image }
        var rgba = image.rgba
        var i = 3
        while i < rgba.count {
            rgba[i] = 255
            i += 4
        }
        return PdfRgbaImage(image.width, image.height, rgba, dpiX: image.dpiX, dpiY: image.dpiY)
    }

    /// True when no pixel has any transparency. With /SMaskInData 0 the alpha is dropped, which only shows the picture as the codecs
    /// give it when it has none: ImageIO returns colour premultiplied, so a pixel with alpha 0 has lost its colour there.
    static func opaque(_ image: PdfRgbaImage) -> Bool {
        var i = 3
        while i < image.rgba.count {
            if image.rgba[i] != 255 { return false }
            i += 4
        }
        return true
    }
}
