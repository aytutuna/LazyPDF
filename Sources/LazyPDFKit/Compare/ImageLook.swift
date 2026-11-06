import Foundation

// Twin of windows/LazyPDF.Core/Compare/ImageLook.cs: what besides its samples decides how a picture looks: how the stored
// bytes are read (filters and their parameters), the colour space, /Decode, masks (ISO 32000-1 8.9.5) and whatever else a
// nested stream says. References are followed, never printed, strings and numbers are taken by value, and an entry that
// says what its absence says is left out, so the same picture keeps its look when objects are renumbered or a value is
// respelled.

final class ImageLook {
    private static let maxDepth = 6
    private static let maxNodes = 1024
    private static let maxItems = 256
    private static let maxBytes = 16 << 20
    private static let keys = ["ColorSpace", "BitsPerComponent", "Decode", "ImageMask", "Mask", "SMask", "Matte"]

    // How a nested stream is stored says nothing about what it holds: its data is judged decoded.
    private static let storageKeys: Set<String> = ["Length", "Filter", "DecodeParms", "DL", "Metadata"]

    private static let filterNames: [String: String] = [
        "Fl": "FlateDecode",
        "LZW": "LZWDecode",
        "AHx": "ASCIIHexDecode",
        "A85": "ASCII85Decode",
        "RL": "RunLengthDecode",
        "CCF": "CCITTFaxDecode",
        "DCT": "DCTDecode",
    ]

    // What a /DecodeParms entry means when absent (ISO 32000-1 7.4.4.3, 7.4.4.4, 7.4.6); a boolean counts as 0 or 1.
    private static let parameterDefaults: [String: Double] = [
        "Predictor": 1,
        "Colors": 1,
        "BitsPerComponent": 8,
        "Columns": 1,
        "EarlyChange": 1,
        "K": 0,
        "Rows": 0,
        "EndOfLine": 0,
        "EncodedByteAlign": 0,
        "BlackIs1": 0,
        "DamagedRowsBeforeError": 0,
    ]

    private let document: PdfDocument
    private var samples: [StreamKey: String] = [:]
    private var nodes = 0

    init(_ document: PdfDocument) {
        self.document = document
    }

    /// Convert.ToHexString.
    static func toHexString(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789ABCDEF".unicodeScalars)
        var text = String.UnicodeScalarView()
        for b in bytes {
            text.append(digits[Int(b >> 4)])
            text.append(digits[Int(b & 15)])
        }
        return String(text)
    }

    static func fingerprint(_ data: [UInt8]) -> String { toHexString(Array(Sha256.hash(data).prefix(12))) }

    func of(_ image: PdfDictionary) throws -> String {
        nodes = 0
        let look = PdfDictionary()
        for key in Self.keys { look[key] = image[key] }
        let stored = try storage(image)
        let described = try entries(look, Self.keys, 0, isImage: true)
        return "|\(stored)|\(described)"
    }

    /// The filters by full name with the parameters that are not the defaults; one filter in an array reads like a bare
    /// name, a null entry like none.
    private func storage(_ image: PdfDictionary) throws -> String {
        var filters: [String] = []
        switch document.resolve(image["Filter"]) {
        case let name as PdfName: filters = [Self.expand(name.value)]
        case let array as PdfArray: filters = array.items.prefix(Self.maxItems).map { Self.expand((document.resolve($0) as? PdfName)?.value ?? "") }
        default: break
        }
        var parameters: [PdfDictionary?] = []
        switch document.resolve(image["DecodeParms"]) {
        case let array as PdfArray: parameters = array.items.prefix(Self.maxItems).map { document.resolve($0) as? PdfDictionary }
        case let dictionary as PdfDictionary: parameters = [dictionary]
        default: break
        }
        var parts: [String] = []
        for (i, filter) in filters.enumerated() {
            if i < parameters.count, let p = parameters[i] {
                let extra = try self.parameters(p, filter)
                parts.append(filter + extra)
            } else {
                parts.append(filter)
            }
        }
        return parts.joined(separator: ",")
    }

    private static func expand(_ filter: String) -> String { filterNames[filter] ?? filter }

    private func parameters(_ parameters: PdfDictionary, _ filter: String) throws -> String {
        let keys = parameters.entries.map { $0.key }.filter { !isDefaultParameter(parameters, $0, filter) }
        let text = try entries(parameters, keys, 1, isImage: false)
        return text == "<>" ? "" : text
    }

    private func isDefaultParameter(_ parameters: PdfDictionary, _ key: String, _ filter: String) -> Bool {
        guard var fallback = Self.parameterDefaults[key] else { return false }
        if key == "Columns" && filter == "CCITTFaxDecode" { fallback = 1728 }
        switch document.resolve(parameters[key]) {
        case let number as PdfNumber: return number.value == fallback
        case let flag as PdfBoolean: return (flag.value ? 1.0 : 0.0) == fallback
        default: return false
        }
    }

    private func entries(_ dictionary: PdfDictionary, _ keys: [String], _ depth: Int, isImage: Bool) throws -> String {
        var parts: [String] = []
        let ordered = Set(keys).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        for key in ordered.prefix(Self.maxItems) {
            guard let value = document.resolve(dictionary[key]), !(value is PdfNull) else { continue }
            if isImage && isDefault(dictionary, key, value) { continue }
            let text = try describe(value, depth)
            parts.append("\(key) \(text)")
        }
        return "<\(parts.joined(separator: " "))>"
    }

    private func describe(_ object: PdfObject?, _ depth: Int) throws -> String {
        let resolved = document.resolve(object)
        if depth >= Self.maxDepth { return "" }
        guard let value = resolved, !(value is PdfNull) else { return "" }
        nodes += 1
        if nodes > Self.maxNodes { return "" }
        try Task.checkCancellation()
        switch value {
        case let stream as PdfStream:
            let keys = stream.dictionary.entries.map { $0.key }.filter { !Self.storageKeys.contains($0) }
            let data = try samplesOf(stream)
            let rest = try entries(stream.dictionary, keys, depth + 1, isImage: stream.dictionary.containsKey("Width"))
            return "S\(data)\(rest)"
        case let dictionary as PdfDictionary:
            return try entries(dictionary, dictionary.entries.map { $0.key }, depth + 1, isImage: false)
        case let array as PdfArray:
            var items: [String] = []
            for item in array.items.prefix(Self.maxItems) { items.append(try describe(item, depth + 1)) }
            return "[\(items.joined(separator: " "))]"
        case let text as PdfString:
            return Self.toHexString(text.bytes)
        case let number as PdfNumber:
            return Self.roundTrip(number.value)
        default:
            return value.description
        }
    }

    /// An entry of an image dictionary that reads as it does when left out (ISO 32000-1 8.9.5, Table 89).
    private func isDefault(_ image: PdfDictionary, _ key: String, _ value: PdfObject) -> Bool {
        let mask = (document.resolve(image["ImageMask"]) as? PdfBoolean)?.value == true
        switch key {
        case "ImageMask", "Interpolate": return (value as? PdfBoolean)?.value == false
        case "BitsPerComponent": return mask && (value as? PdfNumber)?.value == 1
        case "Decode":
            guard let array = value as? PdfArray else { return false }
            return isDefaultDecode(image, array)
        default: return false
        }
    }

    // Table 90: [0 1] for each component, but an Indexed space runs to its last entry and Lab has ranges of its own.
    private func isDefaultDecode(_ image: PdfDictionary, _ decode: PdfArray) -> Bool {
        let values = decode.items.prefix(Self.maxItems).map { (document.resolve($0) as? PdfNumber)?.value }
        if values.isEmpty || values.count % 2 != 0 || values.contains(where: { $0 == nil }) { return false }
        var space = document.resolve(image["ColorSpace"])
        if let family = space as? PdfArray, let first = family.items.first { space = document.resolve(first) }
        var high = 1.0
        switch (space as? PdfName)?.value {
        case "Lab":
            return false
        case "Indexed", "I":
            guard let bits = document.resolve(image["BitsPerComponent"]) as? PdfNumber, bits.value >= 1, bits.value <= 16 else { return false }
            high = Double((1 << Int(bits.value)) - 1)
        default:
            break
        }
        for i in stride(from: 0, to: values.count, by: 2) {
            if values[i] != 0 || values[i + 1] != high { return false }
        }
        return true
    }

    /// A palette or profile is judged by its content: saving may store it with another filter. A stream reached again is not
    /// decoded again.
    private func samplesOf(_ stream: PdfStream) throws -> String {
        if let known = samples[StreamKey(stream)] { return known }
        let data: [UInt8]
        do {
            data = try document.data(stream, Self.maxBytes)
        } catch is PdfReadException {
            data = document.rawData(stream)
        }
        let text = Self.fingerprint(data)
        samples[StreamKey(stream)] = text
        return text
    }

    // double.ToString("R", InvariantCulture): the shortest digits that read back as the same double, in scientific form
    // from 1E+17 up or below 1E-4, with at least two exponent digits.
    private static func roundTrip(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0" }
        let text = "\(abs(value))"
        let halves = text.split(separator: "e", maxSplits: 1)
        let mantissa = halves[0]
        let exponent = halves.count > 1 ? Int(halves[1]) ?? 0 : 0
        let point = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
        var digits = mantissa.filter { $0 != "." }.map { Int(String($0)) ?? 0 }
        var scale = point + exponent
        while digits.first == 0 {
            digits.removeFirst()
            scale -= 1
        }
        while digits.last == 0 { digits.removeLast() }
        let all = digits.map { String($0) }.joined()
        if all.isEmpty { return sign + "0" }
        if scale > 17 || scale < -3 {
            let rest = all.dropFirst()
            let power = abs(scale - 1)
            return sign + String(all.prefix(1)) + (rest.isEmpty ? "" : "." + rest) + "E" + (scale - 1 < 0 ? "-" : "+") + (power < 10 ? "0" : "") + String(power)
        }
        if scale > 0 {
            let whole = all.count > scale ? String(all.prefix(scale)) : all + String(repeating: "0", count: scale - all.count)
            let fraction = all.count > scale ? String(all.dropFirst(scale)) : ""
            return sign + whole + (fraction.isEmpty ? "" : "." + fraction)
        }
        return sign + "0." + String(repeating: "0", count: -scale) + all
    }
}
