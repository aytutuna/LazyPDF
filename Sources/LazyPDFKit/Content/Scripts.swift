// Twin of windows/LazyPDF.Core/Content/Scripts.cs: the right-to-left scripts the writers lay out.

enum Scripts {
    static func isHebrew(_ cp: Int) -> Bool { (cp >= 0x0590 && cp <= 0x05FF) || (cp >= 0xFB1D && cp <= 0xFB4F) }

    static func isArabic(_ cp: Int) -> Bool {
        (cp >= 0x0600 && cp <= 0x06FF) || (cp >= 0x0750 && cp <= 0x077F) || (cp >= 0x08A0 && cp <= 0x08FF)
            || (cp >= 0xFB50 && cp <= 0xFDFF) || (cp >= 0xFE70 && cp <= 0xFEFF)
    }

    static func hasHebrew(_ texts: [String]) -> Bool { texts.contains { $0.unicodeScalars.contains { isHebrew(Int($0.value)) } } }

    static func hasArabic(_ texts: [String]) -> Bool { texts.contains { $0.unicodeScalars.contains { isArabic(Int($0.value)) } } }

    /// Whether the text needs the bidi algorithm: a right-to-left letter, or a mark or embedding that sets a direction.
    static func needsBidi(_ text: String) -> Bool {
        text.unicodeScalars.contains { needsBidi(Int($0.value)) }
    }

    static func needsBidi(_ cp: Int) -> Bool {
        if isHebrew(cp) || isArabic(cp) || isBidiControl(cp) { return true }
        guard cp >= 0x0700 else { return false }
        let type = BidiData.typeOf(cp)
        return type == .r || type == .al || type == .an
    }

    /// A direction mark or embedding control: it sets a direction but has no glyph.
    static func isBidiControl(_ cp: Int) -> Bool {
        cp == 0x200E || cp == 0x200F || cp == 0x061C || (cp >= 0x202A && cp <= 0x202E) || (cp >= 0x2066 && cp <= 0x2069)
    }
}

/// A code point of UTF-16 text with the unit it starts at and its length in units. A lone surrogate counts as U+FFFD,
/// as the C# engine's EnumerateRunes has it.
struct Utf16Rune {
    let value: Int
    let at: Int
    let length: Int

    static func all(_ units: [UInt16]) -> [Utf16Rune] {
        var result: [Utf16Rune] = []
        result.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            let u = Int(units[i])
            if u >= 0xD800 && u < 0xDC00 && i + 1 < units.count && units[i + 1] >= 0xDC00 && units[i + 1] < 0xE000 {
                result.append(Utf16Rune(value: 0x10000 + ((u - 0xD800) << 10) + (Int(units[i + 1]) - 0xDC00), at: i, length: 2))
                i += 2
            } else {
                result.append(Utf16Rune(value: u >= 0xD800 && u < 0xE000 ? 0xFFFD : u, at: i, length: 1))
                i += 1
            }
        }
        return result
    }

    /// The rune at unit `index`, or nil when a valid one does not start there.
    static func at(_ units: [UInt16], _ index: Int) -> Utf16Rune? {
        guard index >= 0 && index < units.count else { return nil }
        let u = Int(units[index])
        if u >= 0xD800 && u < 0xDC00 {
            guard index + 1 < units.count, units[index + 1] >= 0xDC00, units[index + 1] < 0xE000 else { return nil }
            return Utf16Rune(value: 0x10000 + ((u - 0xD800) << 10) + (Int(units[index + 1]) - 0xDC00), at: index, length: 2)
        }
        if u >= 0xDC00 && u < 0xE000 { return nil }
        return Utf16Rune(value: u, at: index, length: 1)
    }
}
