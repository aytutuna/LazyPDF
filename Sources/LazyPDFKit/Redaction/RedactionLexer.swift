import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionLexer.cs: reads content bytes again with none of the repairs
// `ContentParser` makes. What it refuses is what two viewers may split differently: comments, stray delimiters, numbers
// spelled any way but ISO 32000-1 7.3.3 spells them, operands left over at the end, and an inline image dictionary (8.9.7)
// with anything in it but its own keys.

final class RedactionLexer {
    private static let maxDepth = 32
    private static let maxOperands = 256
    private static let maxDigits = 10

    // Inline image keys with their abbreviations (Table 93).
    private static let imageKeys: [String: String] = [
        "BPC": "BitsPerComponent", "BitsPerComponent": "BitsPerComponent", "CS": "ColorSpace", "ColorSpace": "ColorSpace",
        "D": "Decode", "Decode": "Decode", "DP": "DecodeParms", "DecodeParms": "DecodeParms", "F": "Filter", "Filter": "Filter",
        "H": "Height", "Height": "Height", "IM": "ImageMask", "ImageMask": "ImageMask", "I": "Interpolate", "Interpolate": "Interpolate",
        "W": "Width", "Width": "Width", "Intent": "Intent",
    ]

    private enum Read { case value, keyword, bad }

    private let data: [UInt8]
    private let imageEnds: [Int: Int]
    private let breaks: Set<Int>
    private var at = 0

    private init(_ data: [UInt8], _ imageEnds: [Int: Int], _ breaks: Set<Int>) {
        self.data = data
        self.imageEnds = imageEnds
        self.breaks = breaks
    }

    private static func isWhite(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }

    private static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    private static func isRegular(_ c: UInt8) -> Bool { !isWhite(c) && !isDelimiter(c) }

    /// Whether `data` is made only of whole tokens. `imageEnds` gives, for each inline image by the offset of its BI, the
    /// offset after its EI. `breaks` are the offsets of the separators put between content streams (7.8.2): a token, a
    /// string or an image may not run across one, nor may two characters that a viewer reading the streams end to end
    /// would join into one token. A dictionary or array may stay open, and operands may wait for their operator in the
    /// next stream.
    static func whole(_ data: [UInt8], _ imageEnds: [Int: Int], _ breaks: [Int]) -> Bool {
        RedactionLexer(data, imageEnds, Set(breaks)).run()
    }

    private func run() -> Bool {
        for b in breaks {
            if b > 0 && b + 1 < data.count && Self.isRegular(data[b - 1]) && Self.isRegular(data[b + 1]) { return false }
        }
        var pending = 0
        while true {
            skip()
            if at >= data.count { return pending == 0 }
            let start = at
            switch value(0) {
            case .bad:
                return false
            case .value:
                pending += 1
                if pending > Self.maxOperands { return false }
            case .keyword:
                let text = word()
                if !RedactionSyntax.knows(text) { return false }
                if text == "BI" {
                    guard pending == 0, let end = imageEnds[start], dictionary(), end >= at + 1, end <= data.count else { return false }
                    if breaks.contains(where: { $0 >= at && $0 < end }) { return false }
                    at = end
                }
                pending = 0
            }
        }
    }

    private func skip() {
        while at < data.count && Self.isWhite(data[at]) { at += 1 }
    }

    private func word() -> String {
        let start = at
        while at < data.count && Self.isRegular(data[at]) { at += 1 }
        return Latin1.string(Array(data[start..<at]))
    }

    // One operand at the position, or a keyword (nothing consumed), or something that cannot be read.
    private func value(_ depth: Int) -> Read {
        if depth > Self.maxDepth || at >= data.count { return .bad }
        let c = data[at]
        switch c {
        case 0x2F:
            at += 1
            while at < data.count && Self.isRegular(data[at]) { at += 1 }
            return .value
        case 0x28:
            return literal() ? .value : .bad
        case 0x3C where at + 1 < data.count && data[at + 1] == 0x3C:
            return container(depth, true) ? .value : .bad
        case 0x3C:
            return hex() ? .value : .bad
        case 0x5B:
            return container(depth, false) ? .value : .bad
        default:
            break
        }
        if Self.isDelimiter(c) { return .bad }
        let save = at
        let text = word()
        if text == "true" || text == "false" || text == "null" { return .value }
        if (c >= 0x30 && c <= 0x39) || c == 0x2B || c == 0x2D || c == 0x2E { return Self.isNumber(text) ? .value : .bad }
        at = save
        return .keyword
    }

    // Digits with at most one point and one leading sign; no exponent, and an integer part that fits 32 bits (Annex C).
    private static func isNumber(_ text: String) -> Bool {
        let s = Array(text.unicodeScalars)
        var i = s.count > 0 && (s[0] == "+" || s[0] == "-") ? 1 : 0
        var digits = 0, points = 0, whole = 0
        while i < s.count {
            defer { i += 1 }
            if s[i] == "." {
                points += 1
                if points == 1 { continue }
            }
            if s[i] < "0" || s[i] > "9" { return false }
            digits += 1
            if points == 0 { whole += 1 }
        }
        if digits == 0 || whole > maxDigits { return false }
        if whole < maxDigits { return true }
        var integer = 0
        for scalar in s {
            if scalar == "+" || scalar == "-" { continue }
            if scalar == "." { break }
            integer = integer * 10 + Int(scalar.value - 0x30)
        }
        return integer <= Int(Int32.max)
    }

    private func literal() -> Bool {
        var depth = 0
        while at < data.count {
            if breaks.contains(at) { return false }
            switch data[at] {
            case 0x5C:
                at += 1
            case 0x28:
                depth += 1
            case 0x29:
                depth -= 1
                if depth == 0 {
                    at += 1
                    return true
                }
            default:
                break
            }
            at += 1
        }
        return false
    }

    private func hex() -> Bool {
        at += 1
        while at < data.count {
            let c = data[at]
            if c == 0x3E {
                at += 1
                return true
            }
            let digit = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
            if breaks.contains(at) || !(Self.isWhite(c) || digit) { return false }
            at += 1
        }
        return false
    }

    // An array holds values; a dictionary holds a name and a value in turn.
    private func container(_ depth: Int, _ dictionary: Bool) -> Bool {
        at += dictionary ? 2 : 1
        while true {
            skip()
            if at >= data.count { return false }
            if data[at] == (dictionary ? 0x3E : 0x5D) {
                if dictionary && !(at + 1 < data.count && data[at + 1] == 0x3E) { return false }
                at += dictionary ? 2 : 1
                return true
            }
            if dictionary {
                if data[at] != 0x2F || value(depth + 1) != .value { return false }
                skip()
                if at >= data.count || value(depth + 1) != .value { return false }
            } else if value(depth + 1) != .value {
                return false
            }
        }
    }

    // The keys of the image, once each under either spelling, up to ID and the single white space byte after it.
    private func dictionary() -> Bool {
        var seen = Set<String>()
        while true {
            skip()
            if at >= data.count { return false }
            if data[at] != 0x2F {
                if word() != "ID" { return false }
                return at < data.count && Self.isWhite(data[at])
            }
            at += 1
            let start = at
            while at < data.count && Self.isRegular(data[at]) { at += 1 }
            let key = Latin1.string(Array(data[start..<at]))
            guard let canonical = Self.imageKeys[key], seen.insert(canonical).inserted else { return false }
            skip()
            if at >= data.count || value(0) != .value { return false }
        }
    }
}
