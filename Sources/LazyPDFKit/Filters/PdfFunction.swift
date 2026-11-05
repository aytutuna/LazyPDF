import Foundation

// Twin of windows/LazyPDF.Core/Filters/PdfFunction.cs: a PDF function (ISO 32000-1 7.10), sampled (type 0),
// exponential (2), stitching (3) or PostScript calculator (4). Inputs and outputs are clipped to /Domain
// and /Range. The calculator is in PdfPostScript.swift; its class is internal because Swift cannot reach a
// private type from another file.

public class PdfFunction {
    private static let maxDepth = 8
    private static let maxOutputs = 64
    // Array.MaxLength of .NET.
    private static let maxArrayLength = 2_147_483_591

    public internal(set) var inputs = 0
    public internal(set) var outputs = 0

    var domain: [Double] = []
    var range: [Double]?

    init() {}

    /// `output` must hold `outputs` values.
    public func evaluate(_ input: [Double], _ output: inout [Double]) throws {
        var clipped = [Double](repeating: 0, count: min(inputs, 32))
        for i in 0..<clipped.count {
            clipped[i] = PdfFunction.clamp(i < input.count ? input[i] : 0, domain[2 * i], domain[2 * i + 1])
        }
        try compute(clipped, &output)
        guard let range else { return }
        for i in 0..<outputs { output[i] = PdfFunction.clamp(output[i], range[2 * i], range[2 * i + 1]) }
    }

    func compute(_ input: [Double], _ output: inout [Double]) throws {
        preconditionFailure("PdfFunction.compute is overridden by every function type.")
    }

    /// Reads a function dictionary or stream, or an array of one-output functions treated as one.
    /// `decodeStream` gives a stream's data with its filters undone.
    public static func parse(_ function: PdfObject?, _ resolve: (PdfObject?) -> PdfObject?, _ decodeStream: (PdfStream) throws -> [UInt8]) throws -> PdfFunction {
        var parsed: [ObjectIdentifier: PdfFunction] = [:]
        return try parse(function, resolve, decodeStream, 0, &parsed)
    }

    // A function that several others share is parsed once; otherwise a few small objects name each other
    // often enough to take for ever.
    private static func parse(_ function: PdfObject?, _ resolve: (PdfObject?) -> PdfObject?, _ decodeStream: (PdfStream) throws -> [UInt8],
                              _ depth: Int, _ parsed: inout [ObjectIdentifier: PdfFunction]) throws -> PdfFunction {
        if depth > maxDepth { throw PdfReadException.damaged("Functions nest too deep.") }
        let function = resolve(function)
        if let function, let known = parsed[ObjectIdentifier(function)] { return known }
        let result = try parseOne(function, resolve, decodeStream, depth, &parsed)
        if result.outputs > maxOutputs { throw PdfReadException.damaged("A function has too many outputs.") }
        if let function { parsed[ObjectIdentifier(function)] = result }
        return result
    }

    private static func parseOne(_ function: PdfObject?, _ resolve: (PdfObject?) -> PdfObject?, _ decodeStream: (PdfStream) throws -> [UInt8],
                                 _ depth: Int, _ parsed: inout [ObjectIdentifier: PdfFunction]) throws -> PdfFunction {
        if let array = function as? PdfArray {
            if array.items.count == 0 || array.items.count > 64 { throw PdfReadException.damaged("A function array has a bad length.") }
            var parts: [PdfFunction] = []
            for item in array.items { parts.append(try parse(item, resolve, decodeStream, depth + 1, &parsed)) }
            return Combined(parts)
        }
        let dictionary: PdfDictionary
        if let stream = function as? PdfStream {
            dictionary = stream.dictionary
        } else if let d = function as? PdfDictionary {
            dictionary = d
        } else {
            throw PdfReadException.damaged("A function is neither a dictionary nor a stream.")
        }
        guard let domain = numbers(dictionary["Domain"], resolve), domain.count >= 2, domain.count % 2 == 0, domain.count <= 64 else {
            throw PdfReadException.damaged("A function has no usable /Domain.")
        }
        if !ordered(domain) { throw PdfReadException.damaged("A function's /Domain runs backwards.") }
        var range = numbers(dictionary["Range"], resolve)
        if let r = range, r.count % 2 != 0 { range = nil }
        if let r = range, r.count > 2 * maxOutputs || !ordered(r) { throw PdfReadException.damaged("A function has a bad /Range.") }
        let type = PdfFilters.int(resolve(dictionary["FunctionType"]), -1)
        let made: PdfFunction
        switch type {
        case 0: made = try Sampled.create(dictionary, function as? PdfStream, domain, range, resolve, decodeStream)
        case 2: made = try Exponential.create(dictionary, domain, range, resolve)
        case 3: made = try Stitching.create(dictionary, domain, resolve, decodeStream, depth, &parsed)
        case 4: made = try PostScript.create(function as? PdfStream, domain, range, decodeStream)
        default: throw PdfReadException(.unsupported, "Function type \(type) is not supported.")
        }
        made.domain = domain
        made.range = range.flatMap { $0.count >= made.outputs * 2 ? $0 : nil }
        return made
    }

    /// Each (min, max) pair is in order, which a clamp wants.
    static func ordered(_ pairs: [Double]) -> Bool {
        var i = 0
        while i + 1 < pairs.count {
            if pairs[i] > pairs[i + 1] { return false }
            i += 2
        }
        return true
    }

    static func numbers(_ value: PdfObject?, _ resolve: (PdfObject?) -> PdfObject?) -> [Double]? {
        guard let array = resolve(value) as? PdfArray else { return nil }
        var numbers: [Double] = []
        for item in array.items {
            guard let n = resolve(item) as? PdfNumber else { return nil }
            numbers.append(n.value)
        }
        return numbers
    }

    private static func interpolate(_ x: Double, _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> Double {
        x1 == x0 ? y0 : y0 + (x - x0) * (y1 - y0) / (x1 - x0)
    }

    // Math.Clamp: a NaN passes through.
    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        if value < low { return low }
        if value > high { return high }
        return value
    }

    // The C# casts of a double: NaN is 0 and a value out of range saturates.
    static func toInt32(_ x: Double) -> Int {
        x.isNaN ? 0 : Int(max(-2147483648, min(2147483647, x.rounded(.towardZero))))
    }

    static func toInt64(_ x: Double) -> Int {
        if x.isNaN { return 0 }
        if x >= 9.2233720368547758e18 { return Int.max }
        if x <= -9.2233720368547758e18 { return Int.min }
        return Int(x)
    }

    private final class Combined: PdfFunction {
        private let parts: [PdfFunction]

        init(_ parts: [PdfFunction]) {
            self.parts = parts
            super.init()
            inputs = parts[0].inputs
            outputs = parts.reduce(0) { $0 + $1.outputs }
            domain = parts[0].domain
        }

        override func compute(_ input: [Double], _ output: inout [Double]) throws {
            var at = 0
            for part in parts {
                var piece = [Double](repeating: 0, count: part.outputs)
                try part.evaluate(input, &piece)
                for i in 0..<piece.count { output[at + i] = piece[i] }
                at += part.outputs
            }
        }
    }

    private final class Exponential: PdfFunction {
        private var c0: [Double] = [], c1: [Double] = []
        private var n = 1.0

        static func create(_ d: PdfDictionary, _ domain: [Double], _ range: [Double]?, _ resolve: (PdfObject?) -> PdfObject?) throws -> Exponential {
            let c0 = numbers(d["C0"], resolve) ?? [0]
            let c1 = numbers(d["C1"], resolve) ?? [1]
            if c0.count != c1.count || c0.count > 64 { throw PdfReadException.damaged("A type 2 function has unequal /C0 and /C1.") }
            let made = Exponential()
            made.c0 = c0
            made.c1 = c1
            made.n = (resolve(d["N"]) as? PdfNumber)?.value ?? 1
            made.inputs = 1
            made.outputs = c0.count
            return made
        }

        override func compute(_ input: [Double], _ output: inout [Double]) throws {
            let x = n == 1 ? input[0] : pow(input[0], n)
            for i in 0..<c0.count { output[i] = c0[i] + x * (c1[i] - c0[i]) }
        }
    }

    private final class Stitching: PdfFunction {
        private var functions: [PdfFunction] = []
        private var bounds: [Double] = [], encode: [Double] = []

        static func create(_ d: PdfDictionary, _ domain: [Double], _ resolve: (PdfObject?) -> PdfObject?,
                           _ decodeStream: (PdfStream) throws -> [UInt8], _ depth: Int, _ parsed: inout [ObjectIdentifier: PdfFunction]) throws -> Stitching {
            guard let list = resolve(d["Functions"]) as? PdfArray, list.items.count > 0, list.items.count <= 256 else {
                throw PdfReadException.damaged("A type 3 function has no /Functions.")
            }
            var functions: [PdfFunction] = []
            for item in list.items { functions.append(try parse(item, resolve, decodeStream, depth + 1, &parsed)) }
            guard let bounds = numbers(d["Bounds"], resolve), bounds.count == functions.count - 1,
                  let encode = numbers(d["Encode"], resolve), encode.count >= functions.count * 2 else {
                throw PdfReadException.damaged("A type 3 function has bad /Bounds or /Encode.")
            }
            if functions.contains(where: { $0.inputs != 1 || $0.outputs != functions[0].outputs }) {
                throw PdfReadException.damaged("The functions of a type 3 function do not agree.")
            }
            let made = Stitching()
            made.functions = functions
            made.bounds = bounds
            made.encode = encode
            made.inputs = 1
            made.outputs = functions[0].outputs
            return made
        }

        override func compute(_ input: [Double], _ output: inout [Double]) throws {
            let x = input[0]
            var i = 0
            while i < bounds.count && x >= bounds[i] { i += 1 }
            let low = i == 0 ? domain[0] : bounds[i - 1]
            let high = i == bounds.count ? domain[1] : bounds[i]
            let encoded = [PdfFunction.interpolate(x, low, high, encode[2 * i], encode[2 * i + 1])]
            try functions[i].evaluate(encoded, &output)
        }
    }

    private final class Sampled: PdfFunction {
        private var data: [UInt8] = []
        private var size: [Int] = [], stride: [Int] = []
        private var bits = 0
        private var encode: [Double] = [], decode: [Double] = []

        static func create(_ d: PdfDictionary, _ stream: PdfStream?, _ domain: [Double], _ range: [Double]?,
                           _ resolve: (PdfObject?) -> PdfObject?, _ decodeStream: (PdfStream) throws -> [UInt8]) throws -> Sampled {
            let inputs = domain.count / 2
            guard let stream, let range, range.count >= 2 else {
                throw PdfReadException.damaged("A type 0 function needs a stream and a /Range.")
            }
            if inputs > 8 { throw PdfReadException(.unsupported, "A sampled function with more than 8 inputs.") }
            let outputs = range.count / 2
            let bits = PdfFilters.int(resolve(d["BitsPerSample"]), 0)
            guard let sizes = numbers(d["Size"], resolve), sizes.count == inputs, [1, 2, 4, 8, 12, 16, 24, 32].contains(bits) else {
                throw PdfReadException.damaged("A type 0 function has bad /Size or /BitsPerSample.")
            }
            var size = [Int](repeating: 0, count: inputs)
            var stride = [Int](repeating: 0, count: inputs)
            var total = outputs
            for i in 0..<inputs {
                if !(sizes[i] >= 1) || sizes[i] > Double(Int32.max) { throw PdfReadException.damaged("A type 0 function has a bad /Size.") }
                size[i] = Int(sizes[i])
                stride[i] = min(total, Int(Int32.max))
                if size[i] > 8 * maxArrayLength / bits / total { throw PdfReadException.damaged("A type 0 function has too many samples.") }
                total *= size[i]
            }
            let data = try decodeStream(stream)
            if total * bits > data.count * 8 { throw PdfReadException.damaged("A type 0 function has fewer samples than /Size says.") }
            var encode = numbers(d["Encode"], resolve) ?? []
            if encode.count < inputs * 2 { encode = size.flatMap { [0, Double($0 - 1)] } }
            var decode = numbers(d["Decode"], resolve) ?? []
            if decode.count < outputs * 2 { decode = range }
            let made = Sampled()
            made.data = data
            made.size = size
            made.stride = stride
            made.bits = bits
            made.encode = encode
            made.decode = decode
            made.inputs = inputs
            made.outputs = outputs
            return made
        }

        override func compute(_ input: [Double], _ output: inout [Double]) throws {
            var low = [Int](repeating: 0, count: inputs)
            var fraction = [Double](repeating: 0, count: inputs)
            for i in 0..<inputs {
                var e = PdfFunction.interpolate(input[i], domain[2 * i], domain[2 * i + 1], encode[2 * i], encode[2 * i + 1])
                // A NaN does not clamp and leaves a fraction that weighs the corner past the last sample.
                e = e.isNaN ? 0 : PdfFunction.clamp(e, 0, Double(size[i] - 1))
                low[i] = min(PdfFunction.toInt32(e), max(size[i] - 2, 0))
                fraction[i] = e - Double(low[i])
            }
            for j in 0..<outputs { output[j] = 0 }
            let maximum = bits == 32 ? Double(UInt32.max) : Double((1 << bits) - 1)
            for corner in 0..<1 << inputs {
                var weight = 1.0
                var index = 0
                for i in 0..<inputs {
                    let upper = (corner >> i & 1) != 0
                    weight *= upper ? fraction[i] : 1 - fraction[i]
                    index += (low[i] + (upper ? 1 : 0)) * stride[i]
                }
                if weight == 0 { continue }
                for j in 0..<outputs { output[j] += weight * sample(index + j) }
            }
            for j in 0..<outputs {
                output[j] = PdfFunction.interpolate(output[j], 0, maximum, decode[2 * j], decode[2 * j + 1])
            }
        }

        // The indexes are in range once a NaN is kept out; this only stops a mistake from trapping.
        private func byte(_ at: Int) -> Int {
            at >= 0 && at < data.count ? Int(data[at]) : 0
        }

        private func sample(_ index: Int) -> Double {
            let bit = index * bits
            let at = bit >> 3
            switch bits {
            case 8: return Double(byte(at))
            case 16: return Double(byte(at) << 8 | byte(at + 1))
            case 24: return Double(byte(at) << 16 | byte(at + 1) << 8 | byte(at + 2))
            case 32: return Double(byte(at) << 24 | byte(at + 1) << 16 | byte(at + 2) << 8 | byte(at + 3))
            case 12:
                return Double(bit & 7 == 0 ? byte(at) << 4 | byte(at + 1) >> 4 : (byte(at) & 15) << 8 | byte(at + 1))
            default:
                return Double(byte(at) >> (8 - bits - (bit & 7)) & ((1 << bits) - 1))
            }
        }
    }
}
