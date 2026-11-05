import Foundation

// Twin of windows/LazyPDF.Core/Filters/PdfColorSpaces.cs: a colour space (ISO 32000-1 8.6) reduced to what
// turning samples into sRGB needs. `rgb` is the three bytes a conversion fills in.

class SampleColorSpace {
    private static let maxDepth = 8

    let components: Int

    init(_ components: Int) {
        self.components = components
    }

    func min(_ component: Int) -> Double { 0 }

    func max(_ component: Int) -> Double { 1 }

    func toRgb(_ c: [Double], _ rgb: inout [UInt8]) throws {
        preconditionFailure("SampleColorSpace.toRgb is overridden by every colour space.")
    }

    static func parse(_ space: PdfObject?, _ resolve: (PdfObject?) -> PdfObject?, _ decodeStream: (PdfStream) throws -> [UInt8], _ depth: Int = 0) throws -> SampleColorSpace {
        if depth > maxDepth { throw PdfReadException.damaged("Colour spaces nest too deep.") }
        let space = resolve(space)
        if let single = space as? PdfName { return try simple(single.value) }
        guard let array = space as? PdfArray, array.items.count > 0, let family = resolve(array.items[0]) as? PdfName else {
            throw PdfReadException.damaged("A colour space is neither a name nor an array.")
        }
        func item(_ i: Int) -> PdfObject? { i < array.items.count ? resolve(array.items[i]) : nil }
        switch family.value {
        case "ICCBased":
            guard let profile = (item(1) as? PdfStream)?.dictionary else {
                throw PdfReadException.damaged("An ICCBased space has no profile stream.")
            }
            switch PdfFilters.int(resolve(profile["N"]), 0) {
            case 1: return Gray()
            case 3: return Rgb()
            case 4: return Cmyk()
            default: break
            }
            if let alternate = profile["Alternate"] { return try parse(alternate, resolve, decodeStream, depth + 1) }
            throw PdfReadException.damaged("An ICCBased space has no usable /N.")
        case "CalGray": return Gray()
        case "CalRGB": return CalRgb.create(item(1) as? PdfDictionary, resolve)
        case "Lab": return Lab.create(item(1) as? PdfDictionary, resolve)
        case "Indexed", "I":
            return try Indexed.create(item(1), PdfFilters.int(item(2), 0), item(3), resolve, decodeStream, depth)
        case "Separation", "DeviceN":
            let count = family.value == "Separation" ? 1 : (item(1) as? PdfArray)?.items.count ?? 0
            if count < 1 || count > 32 { throw PdfReadException.damaged("A tint space has a bad number of colorants.") }
            let alt = try parse(item(2), resolve, decodeStream, depth + 1)
            let function = try PdfFunction.parse(item(3), resolve, decodeStream)
            if function.inputs != count || function.outputs < alt.components {
                throw PdfReadException.damaged("A tint transform does not fit its colour space.")
            }
            return Tint(count, alt, function)
        case "Pattern":
            throw PdfReadException(.unsupported, "A pattern colour space on an image.")
        default:
            if array.items.count == 1 { return try simple(family.value) }
            throw PdfReadException(.unsupported, "The /\(family.value) colour space is not supported.")
        }
    }

    private static func simple(_ name: String) throws -> SampleColorSpace {
        switch name {
        case "DeviceGray", "G", "CalGray": return Gray()
        case "DeviceRGB", "RGB", "CalRGB": return Rgb()
        case "DeviceCMYK", "CMYK": return Cmyk()
        default: throw PdfReadException(.unsupported, "The /\(name) colour space is not supported.")
        }
    }

    // (byte)(v * 255 + 0.5): a NaN is 0, as the C# cast gives.
    static func byte(_ v: Double) -> UInt8 {
        let scaled = PdfFunction.clamp(v, 0, 1) * 255 + 0.5
        return scaled.isNaN ? 0 : UInt8(scaled)
    }

    final class Gray: SampleColorSpace {
        init() { super.init(1) }

        override func toRgb(_ c: [Double], _ rgb: inout [UInt8]) {
            let v = SampleColorSpace.byte(c[0])
            rgb[0] = v
            rgb[1] = v
            rgb[2] = v
        }
    }

    final class Rgb: SampleColorSpace {
        init() { super.init(3) }

        override func toRgb(_ c: [Double], _ rgb: inout [UInt8]) {
            rgb[0] = SampleColorSpace.byte(c[0])
            rgb[1] = SampleColorSpace.byte(c[1])
            rgb[2] = SampleColorSpace.byte(c[2])
        }
    }

    /// The plain conversion, without a profile: each channel is what the ink leaves, (1 - c)(1 - k).
    final class Cmyk: SampleColorSpace {
        init() { super.init(4) }

        override func toRgb(_ c: [Double], _ rgb: inout [UInt8]) {
            let k = 1 - PdfFunction.clamp(c[3], 0, 1)
            rgb[0] = SampleColorSpace.byte((1 - PdfFunction.clamp(c[0], 0, 1)) * k)
            rgb[1] = SampleColorSpace.byte((1 - PdfFunction.clamp(c[1], 0, 1)) * k)
            rgb[2] = SampleColorSpace.byte((1 - PdfFunction.clamp(c[2], 0, 1)) * k)
        }
    }

    final class CalRgb: SampleColorSpace {
        private var gamma: [Double] = [1, 1, 1]
        private var matrix: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        private var white: [Double] = [0.9505, 1, 1.089]

        init() { super.init(3) }

        static func create(_ d: PdfDictionary?, _ resolve: (PdfObject?) -> PdfObject?) -> CalRgb {
            let result = CalRgb()
            guard let d else { return result }
            if let gamma = PdfFunction.numbers(d["Gamma"], resolve), gamma.count == 3 { result.gamma = gamma }
            if let matrix = PdfFunction.numbers(d["Matrix"], resolve), matrix.count == 9 { result.matrix = matrix }
            if let white = PdfFunction.numbers(d["WhitePoint"], resolve), white.count == 3, white[0] > 0, white[1] > 0, white[2] > 0 {
                result.white = white
            }
            return result
        }

        override func toRgb(_ c: [Double], _ rgb: inout [UInt8]) {
            let a = pow(PdfFunction.clamp(c[0], 0, 1), gamma[0])
            let b = pow(PdfFunction.clamp(c[1], 0, 1), gamma[1])
            let g = pow(PdfFunction.clamp(c[2], 0, 1), gamma[2])
            SampleColorSpace.srgb(matrix[0] * a + matrix[3] * b + matrix[6] * g,
                                  matrix[1] * a + matrix[4] * b + matrix[7] * g,
                                  matrix[2] * a + matrix[5] * b + matrix[8] * g, white, &rgb)
        }
    }

    final class Lab: SampleColorSpace {
        private var range: [Double] = [-100, 100, -100, 100]
        private var white: [Double] = [0.9642, 1, 0.8249]

        init() { super.init(3) }

        static func create(_ d: PdfDictionary?, _ resolve: (PdfObject?) -> PdfObject?) -> Lab {
            let result = Lab()
            guard let d else { return result }
            if let range = PdfFunction.numbers(d["Range"], resolve), range.count == 4, PdfFunction.ordered(range) { result.range = range }
            if let white = PdfFunction.numbers(d["WhitePoint"], resolve), white.count == 3, white[0] > 0, white[1] > 0, white[2] > 0 {
                result.white = white
            }
            return result
        }

        override func min(_ component: Int) -> Double { component == 0 ? 0 : range[(component - 1) * 2] }

        override func max(_ component: Int) -> Double { component == 0 ? 100 : range[(component - 1) * 2 + 1] }

        override func toRgb(_ c: [Double], _ rgb: inout [UInt8]) {
            let m = (PdfFunction.clamp(c[0], 0, 100) + 16) / 116
            let l = m + PdfFunction.clamp(c[1], range[0], range[1]) / 500
            let n = m - PdfFunction.clamp(c[2], range[2], range[3]) / 200
            SampleColorSpace.srgb(white[0] * Lab.inverse(l), white[1] * Lab.inverse(m), white[2] * Lab.inverse(n), white, &rgb)
        }

        private static func inverse(_ x: Double) -> Double {
            x >= 6.0 / 29 ? x * x * x : 108.0 / 841 * (x - 4.0 / 29)
        }
    }

    final class Indexed: SampleColorSpace {
        private var palette: [UInt8] = []
        private(set) var highValue = 0

        init() { super.init(1) }

        static func create(_ baseSpace: PdfObject?, _ high: Int, _ lookup: PdfObject?, _ resolve: (PdfObject?) -> PdfObject?,
                           _ decodeStream: (PdfStream) throws -> [UInt8], _ depth: Int) throws -> Indexed {
            let space = try parse(baseSpace, resolve, decodeStream, depth + 1)
            if space is Indexed { throw PdfReadException.damaged("An Indexed space is based on another.") }
            let high = Swift.min(Swift.max(high, 0), 255)
            let table: [UInt8]
            if let s = lookup as? PdfString {
                table = s.bytes
            } else if let stream = lookup as? PdfStream {
                table = try decodeStream(stream)
            } else {
                throw PdfReadException.damaged("An Indexed space has no lookup table.")
            }
            let n = space.components
            var palette = [UInt8](repeating: 0, count: (high + 1) * 3)
            var comps = [Double](repeating: 0, count: n)
            var rgb = [UInt8](repeating: 0, count: 3)
            for i in 0...high {
                for j in 0..<n {
                    let at = i * n + j
                    let unit = at < table.count ? Double(table[at]) / 255.0 : 0
                    comps[j] = space.min(j) + unit * (space.max(j) - space.min(j))
                }
                try space.toRgb(comps, &rgb)
                for j in 0..<3 { palette[i * 3 + j] = rgb[j] }
            }
            let made = Indexed()
            made.palette = palette
            made.highValue = high
            return made
        }

        override func max(_ component: Int) -> Double { Double(highValue) }

        override func toRgb(_ c: [Double], _ rgb: inout [UInt8]) {
            let index = Swift.min(Swift.max(PdfFunction.toInt32(c[0] + 0.5), 0), highValue)
            for j in 0..<3 { rgb[j] = palette[index * 3 + j] }
        }
    }

    /// Separation and DeviceN: the tint transform gives the alternate space's values.
    final class Tint: SampleColorSpace {
        private let alternate: SampleColorSpace
        private let function: PdfFunction

        init(_ components: Int, _ alternate: SampleColorSpace, _ function: PdfFunction) {
            self.alternate = alternate
            self.function = function
            super.init(components)
        }

        override func toRgb(_ c: [Double], _ rgb: inout [UInt8]) throws {
            var values = [Double](repeating: 0, count: function.outputs)
            try function.evaluate(c, &values)
            for i in 0..<alternate.components { values[i] = PdfFunction.clamp(values[i], alternate.min(i), alternate.max(i)) }
            try alternate.toRgb(values, &rgb)
        }
    }

    /// XYZ relative to `white` to sRGB: the white is scaled to D65, which is crude next to a proper adaptation and enough for a preview.
    private static func srgb(_ x: Double, _ y: Double, _ z: Double, _ white: [Double], _ rgb: inout [UInt8]) {
        let x = x * (0.9505 / white[0])
        let y = y / white[1]
        let z = z * (1.089 / white[2])
        rgb[0] = byte(encode(3.2406 * x - 1.5372 * y - 0.4986 * z))
        rgb[1] = byte(encode(-0.9689 * x + 1.8758 * y + 0.0415 * z))
        rgb[2] = byte(encode(0.0557 * x - 0.2040 * y + 1.0570 * z))
    }

    private static func encode(_ linear: Double) -> Double {
        let linear = PdfFunction.clamp(linear, 0, 1)
        return linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }
}
