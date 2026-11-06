import Foundation

// No twin. What the C# gets from the .NET library and Swift does not have in the same form: String.Trim (every
// Unicode white space character, not just the ASCII ones), LINQ's stable OrderBy, a Dictionary<double, int> read in
// insertion order (MaxBy keeps the first of equal weights; a Swift Dictionary has no order), and char.IsLetter on a
// UTF-16 unit (a character outside the BMP is a surrogate pair there, and no letter).

enum ExportTrim {
    static func start(_ text: String) -> String {
        var scalars = text.unicodeScalars
        while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        return String(scalars)
    }

    static func end(_ text: String) -> String {
        var scalars = text.unicodeScalars
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }

    static func both(_ text: String) -> String { start(end(text)) }
}

enum ExportSort {
    /// `a.CompareTo(b) < 0` for doubles: a NaN comes before every number.
    static func before(_ a: Double, _ b: Double) -> Bool { a.isNaN ? !b.isNaN : a < b }

    /// OrderBy(...).ThenBy(...): elements that compare equal keep their order.
    static func stable<T>(_ items: [T], _ less: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { x, y in
            less(x.element, y.element) || (!less(y.element, x.element) && x.offset < y.offset)
        }.map { $0.element }
    }
}

/// Weights by size in the order the sizes were first seen.
struct SizeWeights {
    private var sizes: [Double] = []
    private var weights: [Int] = []
    private var index: [Double: Int] = [:]

    var isEmpty: Bool { sizes.isEmpty }

    mutating func add(_ size: Double, _ weight: Int) {
        if let at = index[size] {
            weights[at] += weight
        } else {
            index[size] = sizes.count
            sizes.append(size)
            weights.append(weight)
        }
    }

    /// The size with the most weight; the first seen of equal ones.
    var heaviest: Double? {
        var best: Int?
        for i in 0..<sizes.count where best == nil || weights[i] > weights[best ?? 0] { best = i }
        return best.map { sizes[$0] }
    }
}

enum ExportChar {
    static func isLetter(_ c: Unicode.Scalar) -> Bool {
        guard c.value < 0x10000 else { return false }
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    static func isLower(_ c: Unicode.Scalar) -> Bool {
        c.value < 0x10000 && c.properties.generalCategory == .lowercaseLetter
    }

    static func isDigit(_ c: Unicode.Scalar) -> Bool {
        c.value < 0x10000 && c.properties.generalCategory == .decimalNumber
    }

    static func isAsciiDigit(_ c: Unicode.Scalar) -> Bool {
        c.value >= 0x30 && c.value <= 0x39
    }
}

/// String operations of the C# that work on UTF-16 units, done on scalars so that a CR LF pair is not one character.
enum ExportString {
    static func replace(_ text: String, _ from: Unicode.Scalar, _ to: String) -> String {
        var out = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            if c == from { out.append(contentsOf: to.unicodeScalars) } else { out.append(c) }
        }
        return String(out)
    }

    static func split(_ text: String, _ separator: Unicode.Scalar) -> [String] {
        var parts: [String] = []
        var part = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            if c == separator {
                parts.append(String(part))
                part = String.UnicodeScalarView()
            } else {
                part.append(c)
            }
        }
        parts.append(String(part))
        return parts
    }

    /// The text up to `units` UTF-16 units; a character that would be cut in two is left out.
    static func prefix(_ text: String, _ units: Int) -> String {
        var out = String.UnicodeScalarView()
        var count = 0
        for c in text.unicodeScalars {
            count += c.value >= 0x10000 ? 2 : 1
            if count > units { break }
            out.append(c)
        }
        return String(out)
    }

    /// The length in UTF-16 units of the longest line (lines end at LF).
    static func longestLine(_ text: String) -> Int {
        var best = 0, current = 0
        for unit in text.utf16 {
            if unit == 10 {
                best = max(best, current)
                current = 0
            } else {
                current += 1
            }
        }
        return max(best, current)
    }

    /// The white space before, the text between and the white space after (Trim, TrimStart and TrimEnd together).
    static func edges(_ text: String) -> (lead: String, core: String, trail: String) {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        while start < scalars.count && scalars[start].properties.isWhitespace { start += 1 }
        var end = scalars.count
        while end > start && scalars[end - 1].properties.isWhitespace { end -= 1 }
        func make(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(scalars[range])) }
        return (make(0..<start), make(start..<end), make(end..<scalars.count))
    }

    /// `(long)Math.Round(value)`: halves to even, saturated, a NaN as 0.
    static func round(_ value: Double) -> Int { Int(saturating: value.rounded(.toNearestOrEven)) }
}
