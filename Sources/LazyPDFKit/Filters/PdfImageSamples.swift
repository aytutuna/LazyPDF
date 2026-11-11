import Foundation

// Twin of windows/LazyPDF.Core/Filters/PdfImageSamples.cs: image XObject samples (ISO 32000-1 8.9) turned
// into RGBA8.

/// An image as straight (not premultiplied) RGBA8, rows top to bottom.
public struct PdfRgbaImage {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    public let dpiX: Double
    public let dpiY: Double

    public init(_ width: Int, _ height: Int, _ rgba: [UInt8], dpiX: Double = 0, dpiY: Double = 0) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.dpiX = dpiX
        self.dpiY = dpiY
    }
}

public enum PdfImageSamples {
    /// The most pixels one image may have; a bigger one is `PdfReadProblem.unsupported`.
    public static let maxPixels = 1 << 27

    private static let maxRowSamples = 1 << 26

    /// `samples` are the image's data with every filter undone, an image codec's included. `resolve`
    /// follows references; `decodeStream` gives a stream's data with its filters undone (lookup tables,
    /// function samples) and, for a mask image, the decoded samples. Missing samples read as zero. An
    /// image mask comes out black where it paints, transparent elsewhere. Handles inline image keys
    /// (/W, /H, /BPC, /CS, /IM, /D) too.
    public static func toRgba(_ image: PdfDictionary, _ samples: [UInt8], _ resolve: (PdfObject?) -> PdfObject?, _ decodeStream: (PdfStream) throws -> [UInt8]) throws -> PdfRgbaImage {
        let (width, height) = try size(image, resolve)
        let isMask = (resolve(get(image, "ImageMask", "IM")) as? PdfBoolean)?.value == true
        let bpc = isMask ? 1 : PdfFilters.int(resolve(get(image, "BitsPerComponent", "BPC")), 8)
        if ![1, 2, 4, 8, 16].contains(bpc) { throw PdfReadException.damaged("An image with \(bpc) bits per component.") }
        let decode = PdfFunction.numbers(get(image, "Decode", "D"), resolve)

        if isMask {
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let gray = plane(width, height, bpc, decode, samples)
            for i in 0..<gray.count { rgba[i * 4 + 3] = gray[i] < 128 ? 255 : 0 }
            return PdfRgbaImage(width, height, rgba)
        }

        let space = try colorSpaceOf(image, samples, width, height, bpc, resolve, decodeStream)
        if width * space.components > maxRowSamples { throw PdfReadException(.unsupported, "An image row is too wide.") }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try convertPixels(&pixels, width, height, bpc, space, decode, colorKey(image, space.components, resolve), samples)

        if let soft = resolve(image["SMask"]) as? PdfStream {
            try applyMask(&pixels, width, height, soft, false, resolve, decodeStream)
        } else if let hard = resolve(image["Mask"]) as? PdfStream {
            try applyMask(&pixels, width, height, hard, true, resolve, decodeStream)
        }
        return PdfRgbaImage(width, height, pixels)
    }

    private static func get(_ d: PdfDictionary, _ key: String, _ abbreviation: String) -> PdfObject? {
        d[key] ?? d[abbreviation]
    }

    private static func size(_ image: PdfDictionary, _ resolve: (PdfObject?) -> PdfObject?) throws -> (width: Int, height: Int) {
        let width = PdfFilters.int(resolve(get(image, "Width", "W")), 0)
        let height = PdfFilters.int(resolve(get(image, "Height", "H")), 0)
        if width < 1 || height < 1 { throw PdfReadException.damaged("An image has no size.") }
        if width * height > maxPixels || width > maxRowSamples { throw PdfReadException(.unsupported, "An image has too many pixels.") }
        return (width, height)
    }

    private static func colorSpaceOf(_ image: PdfDictionary, _ samples: [UInt8], _ width: Int, _ height: Int, _ bpc: Int,
                                     _ resolve: (PdfObject?) -> PdfObject?, _ decodeStream: (PdfStream) throws -> [UInt8]) throws -> SampleColorSpace {
        if let declared = resolve(get(image, "ColorSpace", "CS")), !(declared is PdfNull) {
            return try SampleColorSpace.parse(declared, resolve, decodeStream)
        }
        // A JPEG 2000 image may leave the space to the codec; the sample count says which it is.
        let perPixel = samples.count * 8 / (width * height * bpc)
        switch perPixel {
        case 1: return SampleColorSpace.Gray()
        case 3: return SampleColorSpace.Rgb()
        case 4: return SampleColorSpace.Cmyk()
        default: throw PdfReadException.damaged("An image has no /ColorSpace.")
        }
    }

    private static func colorKey(_ image: PdfDictionary, _ components: Int, _ resolve: (PdfObject?) -> PdfObject?) -> [Int]? {
        guard let numbers = PdfFunction.numbers(image["Mask"], resolve), numbers.count >= components * 2 else { return nil }
        return numbers.map { PdfFunction.toInt32($0) }
    }

    private static func convertPixels(_ rgba: inout [UInt8], _ width: Int, _ height: Int, _ bpc: Int, _ space: SampleColorSpace,
                                      _ decode: [Double]?, _ key: [Int]?, _ samples: [UInt8]) throws {
        let n = space.components
        let maxRaw = (1 << bpc) - 1
        var minimum = [Double](repeating: 0, count: n)
        var scale = [Double](repeating: 0, count: n)
        var plain = true
        for j in 0..<n {
            var low = space is SampleColorSpace.Indexed ? 0 : space.min(j)
            var high = space is SampleColorSpace.Indexed ? Double(maxRaw) : space.max(j)
            if let decode, decode.count >= 2 * n {
                plain = plain && decode[2 * j] == low && decode[2 * j + 1] == high
                low = decode[2 * j]
                high = decode[2 * j + 1]
            }
            minimum[j] = low
            scale[j] = (high - low) / Double(maxRaw)
        }

        var current = [UInt8](repeating: 0, count: 3)
        var lut: [UInt8]?
        if n == 1 && bpc <= 8 {
            var table = [UInt8](repeating: 0, count: (maxRaw + 1) * 3)
            for v in 0...maxRaw {
                try space.toRgb([minimum[0] + Double(v) * scale[0]], &current)
                for j in 0..<3 { table[v * 3 + j] = current[j] }
            }
            lut = table
        }
        let direct = plain && bpc == 8 && space is SampleColorSpace.Rgb

        let rowBytes = (width * n * bpc + 7) / 8
        var scratch = [UInt8](repeating: 0, count: rowBytes)
        var raw = [Int](repeating: 0, count: width * n)
        var comps = [Double](repeating: 0, count: n)
        var last = [Int](repeating: 0, count: n)
        var haveLast = false
        for y in 0..<height {
            let (source, base) = rowOf(samples, y, rowBytes, &scratch)
            unpack(source, base, bpc, &raw)
            var o = y * width * 4
            for x in 0..<width {
                let p = x * n
                if let lut {
                    let at = raw[p] * 3
                    rgba[o] = lut[at]
                    rgba[o + 1] = lut[at + 1]
                    rgba[o + 2] = lut[at + 2]
                } else if direct {
                    rgba[o] = UInt8(truncatingIfNeeded: raw[p])
                    rgba[o + 1] = UInt8(truncatingIfNeeded: raw[p + 1])
                    rgba[o + 2] = UInt8(truncatingIfNeeded: raw[p + 2])
                } else {
                    var same = haveLast
                    if same { for j in 0..<n where raw[p + j] != last[j] { same = false } }
                    if !same {
                        for j in 0..<n { comps[j] = minimum[j] + Double(raw[p + j]) * scale[j] }
                        try space.toRgb(comps, &current)
                        for j in 0..<n { last[j] = raw[p + j] }
                        haveLast = true
                    }
                    rgba[o] = current[0]
                    rgba[o + 1] = current[1]
                    rgba[o + 2] = current[2]
                }
                var transparent = false
                if let key { transparent = inKey(raw, p, n, key) }
                rgba[o + 3] = transparent ? 0 : 255
                o += 4
            }
        }
    }

    private static func inKey(_ pixel: [Int], _ at: Int, _ count: Int, _ key: [Int]) -> Bool {
        for j in 0..<count where pixel[at + j] < key[2 * j] || pixel[at + j] > key[2 * j + 1] {
            return false
        }
        return true
    }

    /// The row's bytes, from the samples where they are all there, otherwise from the scratch row with the missing ones zero.
    private static func rowOf(_ samples: [UInt8], _ y: Int, _ rowBytes: Int, _ scratch: inout [UInt8]) -> ([UInt8], Int) {
        let start = y * rowBytes
        if start + rowBytes <= samples.count { return (samples, start) }
        for i in 0..<scratch.count { scratch[i] = 0 }
        if start < samples.count {
            for i in 0..<min(scratch.count, samples.count - start) { scratch[i] = samples[start + i] }
        }
        return (scratch, 0)
    }

    private static func unpack(_ row: [UInt8], _ base: Int, _ bpc: Int, _ raw: inout [Int]) {
        switch bpc {
        case 8:
            for i in 0..<raw.count { raw[i] = Int(row[base + i]) }
        case 16:
            for i in 0..<raw.count { raw[i] = Int(row[base + 2 * i]) << 8 | Int(row[base + 2 * i + 1]) }
        default:
            let mask = (1 << bpc) - 1
            for i in 0..<raw.count {
                let bit = i * bpc
                raw[i] = Int(row[base + (bit >> 3)]) >> (8 - bpc - (bit & 7)) & mask
            }
        }
    }

    /// One-component samples as grey bytes, 0 to 255, through /Decode.
    private static func plane(_ width: Int, _ height: Int, _ bpc: Int, _ decode: [Double]?, _ samples: [UInt8]) -> [UInt8] {
        let low = decode.flatMap { $0.count >= 2 ? $0[0] : nil } ?? 0
        let high = decode.flatMap { $0.count >= 2 ? $0[1] : nil } ?? 1
        let maxRaw = (1 << bpc) - 1
        let rowBytes = (width * bpc + 7) / 8
        var scratch = [UInt8](repeating: 0, count: rowBytes)
        var raw = [Int](repeating: 0, count: width)
        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let (source, base) = rowOf(samples, y, rowBytes, &scratch)
            unpack(source, base, bpc, &raw)
            for x in 0..<width { gray[y * width + x] = SampleColorSpace.byte(low + Double(raw[x]) * (high - low) / Double(maxRaw)) }
        }
        return gray
    }

    private static func applyMask(_ rgba: inout [UInt8], _ width: Int, _ height: Int, _ mask: PdfStream, _ stencil: Bool,
                                  _ resolve: (PdfObject?) -> PdfObject?, _ decodeStream: (PdfStream) throws -> [UInt8]) throws {
        let dictionary = mask.dictionary
        let (maskWidth, maskHeight) = try size(dictionary, resolve)
        let imageMask = (resolve(get(dictionary, "ImageMask", "IM")) as? PdfBoolean)?.value == true
        let bpc = stencil || imageMask ? 1 : PdfFilters.int(resolve(get(dictionary, "BitsPerComponent", "BPC")), 8)
        if ![1, 2, 4, 8, 16].contains(bpc) { throw PdfReadException.damaged("A mask with \(bpc) bits per component.") }
        let gray = plane(maskWidth, maskHeight, bpc, PdfFunction.numbers(get(dictionary, "Decode", "D"), resolve), try decodeStream(mask))
        for y in 0..<height {
            let row = (y * maskHeight / height) * maskWidth
            for x in 0..<width {
                let value = gray[row + x * maskWidth / width]
                rgba[(y * width + x) * 4 + 3] = stencil ? (value < 128 ? 255 : 0) : value
            }
        }
    }
}
