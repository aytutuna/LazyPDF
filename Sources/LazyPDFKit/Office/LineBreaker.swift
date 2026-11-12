import Foundation

// Twin of windows/LazyPDF.Core/Office/Layout/LineBreaker.cs: where a line may end, a subset of UAX 14 that covers
// spaces, hyphens, dashes, slashes, no-break characters, quotes and brackets, and Chinese, Japanese text with the
// usual closing and opening marks kept off the line edges. Hangul and everything else breaks only at spaces.

enum LineBreaker {
    private enum Kind {
        case letter, digit, space, tab, newline, zeroWidth, glue, hyphen, after, dash, slash
        case open, close, quote, currency, ideo, ideoOpen, ideoClose
    }

    /// Entry i is true when a line may end before code point i. Entry 0 is never true.
    static func opportunities(_ text: [Int]) -> [Bool] {
        var result = [Bool](repeating: false, count: text.count)
        let kinds = text.map(kindOf)
        // Opening marks keep the word after them even across spaces, so the last solid kind is tracked.
        var solid = Kind.letter
        var i = 1
        while i < text.count {
            switch kinds[i - 1] {
            case .space, .tab, .zeroWidth, .newline: break
            default: solid = kinds[i - 1]
            }
            result[i] = allowed(kinds, i, solid)
            i += 1
        }
        return result
    }

    private static func allowed(_ kinds: [Kind], _ i: Int, _ solid: Kind) -> Bool {
        let before = kinds[i - 1], after = kinds[i]
        if before == .newline { return true }
        if after == .newline { return false }
        if after == .zeroWidth { return false }
        if before == .zeroWidth { return true }
        if after == .space || after == .tab { return false }
        if before == .glue || after == .glue { return false }
        switch after {
        case .close, .slash, .hyphen, .after, .ideoClose, .quote: return false
        default: break
        }
        if before == .space || before == .tab { return solid != .open && solid != .ideoOpen }
        switch before {
        case .open, .ideoOpen, .currency, .quote: return false
        default: break
        }
        if before == .hyphen {
            guard i >= 2 else { return false }
            let two = kinds[i - 2]
            return (two == .letter || two == .digit || two == .ideo) && after != .digit
        }
        if before == .after { return true }
        if before == .slash { return after != .digit }
        if before == .dash || after == .dash { return before != after }
        return isIdeographic(before) || isIdeographic(after)
    }

    private static func isIdeographic(_ kind: Kind) -> Bool { kind == .ideo || kind == .ideoOpen || kind == .ideoClose }

    private static func kindOf(_ c: Int) -> Kind {
        switch c {
        case 0x20, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2008, 0x2009, 0x200A, 0x205F: return .space
        case 0x09: return .tab
        case 0x0A: return .newline
        case 0x200B: return .zeroWidth
        case 0xA0, 0x2007, 0x202F, 0x2011, 0x2060, 0xFEFF: return .glue
        case 0x2D: return .hyphen
        case 0x2010, 0x2012, 0x2013: return .after
        case 0x2014: return .dash
        case 0x2F: return .slash
        case 0x28, 0x5B, 0x7B, 0x201C, 0x2018, 0xAB, 0x2039, 0xA1, 0xBF: return .open
        case 0x29, 0x5D, 0x7D, 0x2C, 0x2E, 0x3A, 0x3B, 0x21, 0x3F, 0x25, 0x201D, 0x2019, 0xBB, 0x203A, 0x2030, 0x2026: return .close
        case 0x22, 0x27: return .quote
        case 0x24, 0xA3, 0xA5, 0x20AC: return .currency
        default: break
        }
        if c >= 0x30 && c <= 0x39 { return .digit }
        if !isIdeograph(c) { return .letter }
        if ideoOpeners.contains(c) { return .ideoOpen }
        if ideoClosers.contains(c) { return .ideoClose }
        return .ideo
    }

    private static func isIdeograph(_ c: Int) -> Bool {
        (c >= 0x2E80 && c <= 0x303F) || (c >= 0x3041 && c <= 0x33FF) || (c >= 0x3400 && c <= 0x4DBF) || (c >= 0x4E00 && c <= 0x9FFF)
            || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF01 && c <= 0xFF60) || (c >= 0xFF61 && c <= 0xFF9F) || (c >= 0xFFE0 && c <= 0xFFE6)
            || (c >= 0x20000 && c <= 0x3FFFF)
    }

    private static let ideoOpeners: Set<Int> = [
        0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014, 0x3016, 0x3018, 0x301A, 0x301D,
        0xFF08, 0xFF3B, 0xFF5B, 0xFF5F, 0xFF62,
    ]

    // Closing marks, small kana, the prolonged sound mark and iteration marks cannot start a line.
    private static let ideoClosers: Set<Int> = [
        0x3001, 0x3002, 0x3005, 0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0x3017, 0x3019, 0x301B, 0x301E, 0x301F,
        0x303B, 0x309B, 0x309C, 0x309D, 0x309E, 0x30FB, 0x30FC, 0x30FD, 0x30FE,
        0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063, 0x3083, 0x3085, 0x3087, 0x308E, 0x3095, 0x3096,
        0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30C3, 0x30E3, 0x30E5, 0x30E7, 0x30EE, 0x30F5, 0x30F6,
        0xFF01, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF1F, 0xFF3D, 0xFF5D, 0xFF60, 0xFF63, 0xFF64, 0xFF9E, 0xFF9F,
    ]
}
