import Foundation

// Twin of windows/LazyPDF.Core/Redaction/ImageRedactor.cs: makes a private copy of an image with the pixels under the marks
// overwritten in the samples, so the covered picture is gone rather than hidden. The copy is stored with Flate. Pictures in a
// lossy or bilevel codec go through the system's decoder; with none, or when it fails, nothing is returned and the caller
// removes the image.

final class ImageRedactor {
    private static let maxSamples = 256 << 20
    private static let maxMaskDepth = 2
    private static let maskKeys = ["SMask", "Mask"]
    // What describes the picture itself (ISO 32000-1 8.9.5); anything else on the dictionary can lead back to the original.
    private static let kept = ["Type", "Subtype", "Width", "Height", "ColorSpace", "BitsPerComponent", "Intent", "ImageMask", "Mask", "Decode", "Interpolate", "SMask", "SMaskInData", "Matte", "StructParent", "OC"]

    private let document: PdfDocument
    private let codec: ImageCodec?

    init(_ document: PdfDocument, _ codec: ImageCodec?) {
        self.document = document
        self.codec = codec
    }

    /// The soft mask and stencil mask of a picture, and theirs in turn as far as `redact` copies: the streams a cut makes private copies of.
    static func masks(_ document: PdfDocument, _ image: PdfStream, _ depth: Int = 0) -> [PdfStream] {
        if depth > maxMaskDepth { return [] }
        var found: [PdfStream] = []
        for key in maskKeys {
            guard let mask = document.stream(image.dictionary, key) else { continue }
            found.append(mask)
            found.append(contentsOf: masks(document, mask, depth + 1))
        }
        return found
    }

    func redact(_ image: PdfStream, _ areas: [MarkArea], _ placement: PdfMatrix) -> PdfReference? {
        guard let back = placement.invert() else { return nil }
        let unit = areas.map { a in a.points.map { back.transform($0.x, $0.y) } }
        do {
            return try copy(image, unit, 0)
        } catch {
            // Whatever goes wrong with one picture, it is removed from the page rather than kept.
            return nil
        }
    }

    private func copy(_ image: PdfStream, _ unit: [[MarkPoint]], _ depth: Int) throws -> PdfReference? {
        // A mask has no masks of its own to speak of; a loop of them is a trap.
        if depth > Self.maxMaskDepth { return nil }
        let d = image.dictionary
        let (filter, parameters, _) = document.decodeSpec(image)
        let decoded = try PdfFilters.decodeToCodec(document.rawData(image), filter, parameters, Self.maxSamples)
        let copy = PdfDictionary()
        for key in Self.kept {
            if let value = d[key] { copy[key] = value }
        }
        copy["Filter"] = PdfName("FlateDecode")
        if try !copyMasks(d, copy, unit, depth) { return nil }

        guard let name = decoded.codec else {
            let width = Int(Int32(truncatingIfNeeded: document.integer(d, "Width") ?? 0))
            let height = Int(Int32(truncatingIfNeeded: document.integer(d, "Height") ?? 0))
            if !Self.fits(width, height) { return nil }
            let mask = document.bool(d, "ImageMask") == true
            let bits = mask ? 1 : Int(Int32(truncatingIfNeeded: document.integer(d, "BitsPerComponent") ?? 8))
            let components = try mask ? 1 : SampleColorSpace.parse(d["ColorSpace"], { self.document.resolve($0) }, { try self.document.data($0) }).components
            var samples = decoded.data
            // The C# multiplies in long without a check; a size that does not fit, or is negative, is no picture to keep.
            let (perPixel, o1) = components.multipliedReportingOverflow(by: bits)
            let (row, o2) = width.multipliedReportingOverflow(by: perPixel)
            let (padded, o3) = row.addingReportingOverflow(7)
            let (used, o4) = (padded / 8).multipliedReportingOverflow(by: height)
            if o1 || o2 || o3 || o4 || used < 0 { return nil }
            if samples.count > used { samples = Array(samples[0..<used]) }
            Self.zero(&samples, width, height, perPixel, unit)
            return try document.add(PdfStream(copy, data: PdfFilterEncoders.flate(samples)))
        }

        guard let pixels = codec?.decode(decoded.data, name), Self.fits(pixels.width, pixels.height),
              pixels.rgba.count == pixels.width * pixels.height * 4 else { return nil }
        var rgba = pixels.rgba
        for (row, from, to) in Self.cells(pixels.width, pixels.height, pixels.height, unit) {
            for x in from..<to {
                let i = (row * pixels.width + x) * 4
                (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]) = (0, 0, 0, 255)
            }
        }
        if name == "JBIG2Decode" {
            copy["Width"] = PdfNumber(pixels.width)
            copy["Height"] = PdfNumber(pixels.height)
            return try document.add(PdfStream(copy, data: PdfFilterEncoders.flate(Self.bilevel(rgba, pixels.width, pixels.height))))
        }
        let reference = try ContentImages.addRgba(document, pixels.width, pixels.height, rgba)
        guard let made = document.get(reference.number) as? PdfStream else { return nil }
        for key in Self.maskKeys {
            if let mask = copy[key] { made.dictionary[key] = mask }
        }
        return reference
    }

    private static func fits(_ width: Int, _ height: Int) -> Bool {
        width > 0 && height > 0 && width * height <= PdfImageSamples.maxPixels
    }

    // The soft mask and the stencil mask hold picture data of their own, at their own size.
    private func copyMasks(_ source: PdfDictionary, _ copy: PdfDictionary, _ unit: [[MarkPoint]], _ depth: Int) throws -> Bool {
        for key in Self.maskKeys {
            guard let mask = document.stream(source, key) else { continue }
            guard let reference = try self.copy(mask, unit, depth + 1) else { return false }
            copy[key] = reference
        }
        return true
    }

    private static func zero(_ data: inout [UInt8], _ width: Int, _ height: Int, _ bitsPerPixel: Int, _ unit: [[MarkPoint]]) {
        let (wide, o1) = width.multipliedReportingOverflow(by: bitsPerPixel)
        let (padded, o2) = wide.addingReportingOverflow(7)
        if o1 || o2 { return }
        let stride = padded / 8
        let rows = min(height, (data.count + stride - 1) / max(stride, 1))
        for (row, from, to) in cells(width, rows, height, unit) {
            let (start, o3) = row.multipliedReportingOverflow(by: stride)
            if o3 || start >= data.count { continue }
            let bitFrom = from * bitsPerPixel, bitTo = to * bitsPerPixel
            var b = bitFrom / 8
            while b <= (bitTo - 1) / 8 {
                if start + b >= data.count { break }
                let lo = max(bitFrom, b * 8) - b * 8, hi = min(bitTo, b * 8 + 8) - b * 8
                let mask = (0xFF >> lo) & (0xFF << (8 - hi))
                data[start + b] &= UInt8(truncatingIfNeeded: ~mask)
                b += 1
            }
        }
    }

    private static func bilevel(_ rgba: [UInt8], _ width: Int, _ height: Int) -> [UInt8] {
        let stride = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if Int(rgba[i]) + Int(rgba[i + 1]) + Int(rgba[i + 2]) >= 384 { bits[y * stride + x / 8] |= UInt8(0x80 >> (x % 8)) }
            }
        }
        return bits
    }

    /// The runs of pixels, per row, that any part of a marked polygon touches. The polygons are in the unit square, y up.
    private static func cells(_ width: Int, _ rows: Int, _ height: Int, _ unit: [[MarkPoint]]) -> [(row: Int, from: Int, to: Int)] {
        var runs: [(row: Int, from: Int, to: Int)] = []
        for polygon in unit {
            let pixels: [MarkPoint] = polygon.map { ($0.x * Double(width), (1 - $0.y) * Double(height)) }
            let top = Int(saturating32: nanMax(0, Geometry.minimum(pixels.map { $0.y }).rounded(.down)))
            let bottom = Int(saturating32: nanMin(Double(rows), Geometry.maximum(pixels.map { $0.y }).rounded(.up)))
            var row = top
            while row < bottom {
                defer { row += 1 }
                let above = half(pixels) { $0.y - Double(row) }
                let strip = half(above) { Double(row) + 1 - $0.y }
                if strip.count < 3 || Geometry.area(strip) < 1e-6 { continue }
                let from = Int(saturating32: nanMax(0, Geometry.minimum(strip.map { $0.x }).rounded(.down)))
                let to = Int(saturating32: nanMin(Double(width), Geometry.maximum(strip.map { $0.x }).rounded(.up)))
                if to > from { runs.append((row, from, to)) }
            }
        }
        return runs
    }

    // The part of a polygon on the side where the measure is not negative.
    private static func half(_ polygon: [MarkPoint], _ measure: (MarkPoint) -> Double) -> [MarkPoint] {
        var output: [MarkPoint] = []
        for i in 0..<polygon.count {
            let (cur, prev) = (polygon[i], polygon[(i + polygon.count - 1) % polygon.count])
            let mc = measure(cur), mp = measure(prev)
            if (mc >= 0) != (mp >= 0) {
                let t = mp / (mp - mc)
                output.append((prev.x + t * (cur.x - prev.x), prev.y + t * (cur.y - prev.y)))
            }
            if mc >= 0 { output.append(cur) }
        }
        return output
    }
}
