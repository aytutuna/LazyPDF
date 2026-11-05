import Foundation

// No twin. The C# works on UTF-16 `char`s and on `double.CompareTo`; these give the same answers for a UTF-16 unit of
// a Swift String (a surrogate half has no category, so it is no letter and no white space, as in .NET) and for a
// double that is NaN (which sorts before every number).

extension UInt16 {
    /// `char.IsLetter`.
    var isLetter: Bool {
        if self < 0x80 { return (self >= 0x41 && self <= 0x5A) || (self >= 0x61 && self <= 0x7A) }
        guard let scalar = Unicode.Scalar(self) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// `char.IsLetterOrDigit`.
    var isLetterOrDigit: Bool {
        if isLetter { return true }
        guard let scalar = Unicode.Scalar(self) else { return false }
        return scalar.properties.generalCategory == .decimalNumber
    }

    /// `char.IsLower`.
    var isLower: Bool {
        guard let scalar = Unicode.Scalar(self) else { return false }
        return scalar.properties.generalCategory == .lowercaseLetter
    }

    /// `char.IsWhiteSpace`.
    var isWhiteSpace: Bool {
        if self < 0x80 { return self == 0x20 || (self >= 0x09 && self <= 0x0D) }
        guard let scalar = Unicode.Scalar(self) else { return false }
        return scalar.properties.isWhitespace
    }

    var isNonSpacingMark: Bool {
        guard let scalar = Unicode.Scalar(self) else { return false }
        return scalar.properties.generalCategory == .nonspacingMark
    }

    /// `char.ToLowerInvariant`: the simple one-to-one mapping, a unit on its own (a surrogate half stays).
    var lowercasedInvariant: UInt16 {
        if self < 0x80 { return self >= 0x41 && self <= 0x5A ? self + 0x20 : self }
        guard let scalar = Unicode.Scalar(self) else { return self }
        let mapped = scalar.properties.lowercaseMapping.unicodeScalars
        guard mapped.count == 1, let first = mapped.first, first.value <= 0xFFFF else { return self }
        return UInt16(first.value)
    }
}

extension String {
    init(units: [UInt16]) {
        self.init(decoding: units, as: UTF16.self)
    }
}

/// `double.CompareTo`.
func compareDoubles(_ a: Double, _ b: Double) -> Int {
    if a < b { return -1 }
    if a > b { return 1 }
    if a == b { return 0 }
    if a.isNaN { return b.isNaN ? 0 : -1 }
    return 1
}
