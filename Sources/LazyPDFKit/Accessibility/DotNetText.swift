import Foundation

// No C# twin: what string.Trim(), string.Split(null), char.IsDigit and char.IsLetter do, which is to work on UTF-16 units
// and to take the Unicode White_Space set. Swift's own tests work on characters, so "\r\n" and a letter with a combining
// mark would count differently.

enum DotNetText {
    static func isWhiteSpace(_ unit: UInt16) -> Bool {
        (unit >= 0x09 && unit <= 0x0D) || unit == 0x20 || unit == 0x85 || unit == 0xA0 || unit == 0x1680
            || (unit >= 0x2000 && unit <= 0x200A) || unit == 0x2028 || unit == 0x2029 || unit == 0x202F || unit == 0x205F
            || unit == 0x3000
    }

    static func isDigit(_ unit: UInt16) -> Bool {
        category(unit) == .decimalNumber
    }

    static func isLetter(_ unit: UInt16) -> Bool {
        switch category(unit) {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    private static func category(_ unit: UInt16) -> Unicode.GeneralCategory? {
        Unicode.Scalar(unit)?.properties.generalCategory
    }

    static func trim(_ text: String) -> String {
        trimEnd(trimStart(text))
    }

    static func trimStart(_ text: String) -> String {
        var units = Array(text.utf16)[...]
        while let first = units.first, isWhiteSpace(first) { units = units.dropFirst() }
        return String(decoding: units, as: UTF16.self)
    }

    static func trimEnd(_ text: String) -> String {
        var units = Array(text.utf16)[...]
        while let last = units.last, isWhiteSpace(last) { units = units.dropLast() }
        return String(decoding: units, as: UTF16.self)
    }

    static func isNullOrWhiteSpace(_ text: String?) -> Bool {
        text?.utf16.allSatisfy { isWhiteSpace($0) } ?? true
    }

    /// `string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))`.
    static func words(_ text: String) -> String {
        var parts: [[UInt16]] = []
        var current: [UInt16] = []
        for unit in text.utf16 {
            if isWhiteSpace(unit) {
                if !current.isEmpty { parts.append(current) }
                current = []
            } else {
                current.append(unit)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { String(decoding: $0, as: UTF16.self) }.joined(separator: " ")
    }

    /// The simple lower case mapping, as ToLowerInvariant does: a letter whose full mapping is more than one character stays.
    static func lowerInvariant(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let lower = scalar.properties.lowercaseMapping.unicodeScalars
            if lower.count == 1, let mapped = lower.first {
                result.append(mapped)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }
}
