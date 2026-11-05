import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportImageMerge.cs: puts the colour space, /Decode, colour key and mask of an
// image on its pixels, whether the samples came out of the filters or out of an image codec. A mask stored with a codec
// of its own goes through the codec too (ISO 32000-1 8.9.6).
//
// A codec's picture whose pixel buffer does not fit its size is read as a picture the codec could not read, where the C#
// would index past the buffer.

final class ExportImageMerge {
    private static let coders = ["DCTDecode", "DCT", "JPXDecode", "JBIG2Decode"]

    private let document: PdfDocument
    private let codec: ImageCodec?
    private let pixelBudget: Int
    private var charged = 0

    init(_ document: PdfDocument, _ codec: ImageCodec?, _ pixelBudget: Int) {
        self.document = document
        self.codec = codec
        self.pixelBudget = pixelBudget
    }

    private func resolve(_ value: PdfObject?) -> PdfObject? { document.resolve(value) }

    private func data(_ stream: PdfStream) throws -> [UInt8] { try document.data(stream) }

    /// Counts pixels about to be decoded; past the budget it throws, and the picture is left out.
    func charge(_ count: Int) throws {
        let (sum, overflow) = charged.addingReportingOverflow(count)
        charged = overflow ? (count > 0 ? Int.max : Int.min) : sum
        if charged > pixelBudget { throw PdfReadException(.unsupported, ExportText.tooLarge) }
    }

    /// True when a JPEG file made of `jpeg` shows what the page shows.
    func showsAsFile(_ dictionary: PdfDictionary, _ jpeg: [UInt8]) throws -> Bool {
        if present(dictionary["SMask"]) || present(dictionary["Mask"]) || document.bool(dictionary, "ImageMask") == true { return false }
        let decode = PdfFunction.numbers(dictionary["Decode"], resolve)
        let identity = decode.map { Self.pairs($0, $0.count).allSatisfy { $0 == (0, 1) } } ?? true
        do {
            let space = try self.space(dictionary)
            if space is SampleColorSpace.Cmyk { return identity ? !Self.hasAdobeMarker(jpeg) : Self.inverts(decode) && Self.hasAdobeMarker(jpeg) }
            return identity && (space == nil || space is SampleColorSpace.Gray || space is SampleColorSpace.Rgb)
        } catch is PdfReadException {
            return identity
        }
    }

    func fromSamples(_ dictionary: PdfDictionary, _ samples: [UInt8]) throws -> PdfRgbaImage {
        let (plain, mask, stencil) = try split(dictionary, all: false)
        return try apply(try PdfImageSamples.toRgba(plain, samples, resolve, data), mask, stencil)
    }

    /// `pixels` are the codec's, sRGB already. A space of one or three components is given back to the samples code as
    /// samples, so /Decode, the tint transform and a colour key apply as for any image. Any other space, and one that
    /// cannot be read, is taken as the codec left it: the inks of a DeviceN image cannot be recovered from its RGB. A CMYK
    /// image is brought to what the page shows (see `cmykView`). `coded` is the codec's input.
    func fromPixels(_ dictionary: PdfDictionary, _ decoded: PdfRgbaImage, _ coder: String, _ coded: [UInt8]) throws -> PdfRgbaImage {
        var pixels = decoded
        if coder == "JPXDecode" { pixels = Self.jpxAlpha(pixels, document.integer(dictionary, "SMaskInData") ?? 0) }
        let imageMask = document.bool(dictionary, "ImageMask") == true
        var space: SampleColorSpace?
        var readable = true
        do {
            if !imageMask { space = try self.space(dictionary) }
        } catch is PdfReadException {
            readable = false
        }
        let n = imageMask ? 1 : (space?.components ?? 3)
        let samples = readable && (n == 1 || n == 3)
        let (plain, mask, stencil) = try split(dictionary, all: !samples)
        if !samples {
            if let space, space.components == 4 {
                pixels = try cmykView(dictionary, pixels, space, coder == "DCTDecode" && Self.hasAdobeMarker(coded))
            }
            return try apply(pixels, mask, stencil)
        }

        plain["Width"] = PdfNumber(pixels.width)
        plain["Height"] = PdfNumber(pixels.height)
        // /Decode does not apply to JPEG 2000 data (ISO 32000-1 Table 89).
        if coder == "JPXDecode" && !imageMask { plain.remove("Decode") }
        let bits = imageMask || coder == "JBIG2Decode"
        if !imageMask { plain["BitsPerComponent"] = PdfNumber(bits ? 1 : 8) }

        var converted = try PdfImageSamples.toRgba(plain, Self.pack(pixels, n, bits), resolve, data)
        if coder == "JPXDecode", let mode = document.integer(dictionary, "SMaskInData"), mode > 0 {
            var rgba = converted.rgba
            var i = 3
            while i < rgba.count && i < pixels.rgba.count {
                rgba[i] = UInt8(truncatingIfNeeded: Int(rgba[i]) * Int(pixels.rgba[i]) / 255)
                i += 4
            }
            converted = PdfRgbaImage(converted.width, converted.height, rgba)
        }
        return try apply(converted, mask, stencil)
    }

    // ISO 32000-1 Table 89: 0 leaves the codestream's alpha out, 1 takes it as straight alpha, 2 as premultiplied.
    private static func jpxAlpha(_ image: PdfRgbaImage, _ mode: Int) -> PdfRgbaImage {
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
        return PdfRgbaImage(image.width, image.height, rgba)
    }

    // The consecutive pairs of `values`, at most `limit`, the last alone when the count is odd (LINQ Chunk(2)).
    private static func pairs(_ values: [Double], _ limit: Int) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        var i = 0
        while i < values.count && result.count < limit {
            result.append((values[i], i + 1 < values.count ? values[i + 1] : Double.nan))
            i += 2
        }
        return result
    }

    private static func inverts(_ decode: [Double]?) -> Bool {
        guard let decode, decode.count >= 8 else { return false }
        return pairs(decode, 4).allSatisfy { $0 == (1, 0) }
    }

    // The Adobe marker (APP14) tells a codec that the stored inks are inverted.
    private static func hasAdobeMarker(_ jpeg: [UInt8]) -> Bool {
        var p = 2
        while p + 4 <= jpeg.count && jpeg[p] == 0xFF && jpeg[p + 1] != 0xDA {
            let length = Int(jpeg[p + 2]) << 8 | Int(jpeg[p + 3])
            if jpeg[p + 1] == 0xEE && length >= 7 && p + 9 <= jpeg.count && jpeg[p + 4] == UInt8(ascii: "A") && jpeg[p + 5] == UInt8(ascii: "d") { return true }
            p += 2 + length
        }
        return false
    }

    // A codec shows an Adobe-marked CMYK JPEG the way a JPEG file looks and an unmarked one as stored.
    // A page shows the stored inks after /Decode, so the two differ when the marker and a reversing
    // /Decode disagree; the RGB inverse stands in for the ink inverse, which RGB cannot give back.
    private func cmykView(_ dictionary: PdfDictionary, _ pixels: PdfRgbaImage, _ space: SampleColorSpace, _ marked: Bool) throws -> PdfRgbaImage {
        let decode = PdfFunction.numbers(dictionary["Decode"], resolve)
        var rgba = pixels.rgba
        if marked != Self.inverts(decode) {
            for i in 0..<rgba.count where i % 4 != 3 { rgba[i] = 255 - rgba[i] }
        }
        if let key = PdfFunction.numbers(dictionary["Mask"], resolve), key.count >= 8 { try Self.key(&rgba, key, decode, space) }
        return PdfRgbaImage(pixels.width, pixels.height, rgba)
    }

    // The colour key (ISO 32000-1 8.9.6.4) is matched against the RGB of the corners of its ink range.
    private static func key(_ rgba: inout [UInt8], _ key: [Double], _ decode: [Double]?, _ space: SampleColorSpace) throws {
        var ink = [Double](repeating: 0, count: 4)
        var rgb = [UInt8](repeating: 0, count: 3)
        var low = [255, 255, 255], high = [0, 0, 0]
        let decoded = (decode?.count ?? 0) >= 8
        for corner in 0..<16 {
            for j in 0..<4 {
                let from = decoded ? decode?[2 * j] ?? 0 : space.min(j), to = decoded ? decode?[2 * j + 1] ?? 0 : space.max(j)
                ink[j] = from + key[2 * j + (corner >> j & 1)] * (to - from) / 255
            }
            try space.toRgb(ink, &rgb)
            for c in 0..<3 {
                low[c] = min(low[c], Int(rgb[c]))
                high[c] = max(high[c], Int(rgb[c]))
            }
        }
        var i = 0
        while i + 3 < rgba.count {
            var inside = true
            for c in 0..<3 { inside = inside && Int(rgba[i + c]) >= low[c] && Int(rgba[i + c]) <= high[c] }
            if inside { rgba[i + 3] = 0 }
            i += 4
        }
    }

    private func present(_ value: PdfObject?) -> Bool {
        let resolved = document.resolve(value)
        return resolved != nil && !(resolved is PdfNull)
    }

    private func space(_ dictionary: PdfDictionary) throws -> SampleColorSpace? {
        present(dictionary["ColorSpace"])
            ? try SampleColorSpace.parse(dictionary["ColorSpace"], resolve, data)
            : nil
    }

    // The samples code applies a mask of plain filters itself; the rest is left for apply.
    private func split(_ dictionary: PdfDictionary, all: Bool) throws -> (plain: PdfDictionary, mask: PdfStream?, stencil: Bool) {
        let plain = dictionary.copy()
        if let soft = document.resolve(dictionary["SMask"]) as? PdfStream {
            try chargeMask(soft)
            // A soft mask overrides /Mask (ISO 32000-1 8.9.6.5), so a /Mask stream is never read.
            plain.remove("Mask")
            if !all && !isCoded(soft) { return (plain, nil, false) }
            plain.remove("SMask")
            return (plain, soft, false)
        }
        if let hard = document.resolve(dictionary["Mask"]) as? PdfStream {
            try chargeMask(hard)
            if !all && !isCoded(hard) { return (plain, nil, false) }
            plain.remove("Mask")
            return (plain, hard, true)
        }
        return (plain, nil, false)
    }

    // A coded mask is charged for what the codec returns; an unreadable size is refused later and costs
    // nothing. The size is read as the samples code reads it, /W and /H included.
    private func chargeMask(_ mask: PdfStream) throws {
        if isCoded(mask) { return }
        let d = mask.dictionary
        let width = PdfFilters.int(document.resolve(d["Width"] ?? d["W"]), 0), height = PdfFilters.int(document.resolve(d["Height"] ?? d["H"]), 0)
        if width >= 1 && height >= 1 && width <= PdfImageSamples.maxPixels / height { try charge(width * height) }
    }

    private func isCoded(_ stream: PdfStream) -> Bool {
        switch document.decodeSpec(stream).filter {
        case let name as PdfName: return Self.coders.contains(name.value)
        case let array as PdfArray: return array.items.contains { ($0 as? PdfName).map { Self.coders.contains($0.value) } ?? false }
        default: return false
        }
    }

    private static func pack(_ image: PdfRgbaImage, _ components: Int, _ bits: Bool) -> [UInt8] {
        let w = image.width, h = image.height
        let rgba = image.rgba
        if bits {
            let row = (w + 7) / 8
            var packed = [UInt8](repeating: 0, count: row * h)
            for y in 0..<h {
                for x in 0..<w where rgba[(y * w + x) * 4] >= 128 { packed[y * row + x / 8] |= UInt8(0x80 >> (x % 8)) }
            }
            return packed
        }
        var samples = [UInt8](repeating: 0, count: w * h * components)
        for i in 0..<(w * h) {
            for c in 0..<components { samples[i * components + c] = rgba[i * 4 + c] }
        }
        return samples
    }

    // The alpha of the mask, sampled nearest where the sizes differ.
    private func apply(_ image: PdfRgbaImage, _ mask: PdfStream?, _ stencil: Bool) throws -> PdfRgbaImage {
        guard let mask, let (mw, mh, alpha) = try plane(mask, stencil) else { return image }
        var rgba = image.rgba
        for y in 0..<image.height {
            let row = Int(Int64(y) * Int64(mh) / Int64(image.height)) * mw
            for x in 0..<image.width { rgba[(y * image.width + x) * 4 + 3] = alpha[row + Int(Int64(x) * Int64(mw) / Int64(image.width))] }
        }
        return PdfRgbaImage(image.width, image.height, rgba)
    }

    // Nil when a codec is needed and cannot read the mask: the picture stays opaque.
    private func plane(_ mask: PdfStream, _ stencil: Bool) throws -> (width: Int, height: Int, alpha: [UInt8])? {
        let (filter, parameters, _) = document.decodeSpec(mask)
        let decoded = try PdfFilters.decodeToCodec(document.rawData(mask), filter, parameters)
        var image: PdfRgbaImage?
        var inverted = false
        if decoded.codec == nil {
            image = try PdfImageSamples.toRgba(mask.dictionary, decoded.data, resolve, data)
        } else if let coder = decoded.codec {
            try charge(0)
            image = codec?.decode(decoded.data, coder)
            if let image { try charge(Self.area(image) ?? Int.max) }
            if let d = PdfFunction.numbers(mask.dictionary["Decode"], resolve), d.count >= 2 { inverted = d[0] > d[1] }
        }
        guard let image, let size = Self.area(image), image.width >= 1, image.height >= 1, size <= PdfImageSamples.maxPixels,
              image.rgba.count == size * 4 else { return nil }

        // An image mask decoded from samples already says where it paints in its alpha.
        let painted = decoded.codec == nil && document.bool(mask.dictionary, "ImageMask") == true
        var alpha = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            let value: UInt8 = painted ? image.rgba[i * 4 + 3] : inverted ? 255 - image.rgba[i * 4] : image.rgba[i * 4]
            alpha[i] = stencil && !painted ? (value < 128 ? 255 : 0) : value
        }
        return (image.width, image.height, alpha)
    }

    /// Width times height of a picture; nil when the product overflows.
    static func area(_ image: PdfRgbaImage) -> Int? {
        let (size, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        return overflow ? nil : size
    }
}
