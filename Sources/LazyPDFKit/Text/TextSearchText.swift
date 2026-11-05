import Foundation

// Twin of windows/LazyPDF.Core/Text/TextSearchText.cs: a page's text as a search sees it, white space runs and line
// breaks become one space, case and diacritics are folded as asked, and every character of it points back at the page
// character it came from. Text is held as UTF-16 units, as the C# string is, so the positions mean the same.

final class SearchText {
    var text: [UInt16] = []
    var map: [Int] = []

    /// The page has a hyphen at a line end that a join would take out.
    var hasHyphenBreak = false

    static func build(_ page: TextPage, _ options: TextSearchOptions, _ dropHyphens: Bool) -> SearchText {
        var sb: [UInt16] = []
        var map: [Int] = []
        sb.reserveCapacity(page.chars.count + 16)
        map.reserveCapacity(page.chars.count + 16)
        var hyphenBreak = false
        var line = -1
        var soft = false

        func space(_ index: Int) {
            if sb.isEmpty || sb[sb.count - 1] == 0x20 { return }
            sb.append(0x20)
            map.append(index)
        }

        for c in page.chars {
            if c.line != line {
                if line >= 0 && !sb.isEmpty && sb[sb.count - 1] != 0x20 {
                    if soft && page.lines[c.line].before == .line {
                        hyphenBreak = true
                    } else if page.lines[c.line].before == .line && !c.isSpace && joinsAfterHyphen(sb, c) {
                        hyphenBreak = true
                        if dropHyphens {
                            sb.removeLast()
                            map.removeLast()
                        }
                    } else {
                        space(c.index)
                    }
                }
                line = c.line
                soft = false
            }
            if c.isSpace {
                space(c.index)
                continue
            }
            if c.text == "\u{AD}" {
                soft = true
                continue
            }
            soft = false
            for f in fold(Array(c.text.utf16), options) {
                sb.append(f)
                map.append(c.index)
            }
        }
        let result = SearchText()
        result.text = sb
        result.map = map
        result.hasHyphenBreak = hyphenBreak
        return result
    }

    private static func joinsAfterHyphen(_ sb: [UInt16], _ next: TextChar) -> Bool {
        guard sb.count >= 2, let letter = next.text.utf16.first else { return false }
        let hyphen = sb[sb.count - 1]
        return (hyphen == 0x2D || hyphen == 0x2010 || hyphen == 0x2011) && sb[sb.count - 2].isLetter && letter.isLetter
    }

    // Dotless i is a different letter until diacritics are folded; dotted capital I is always i.
    static func fold(_ text: String, _ options: TextSearchOptions) -> String {
        String(units: fold(Array(text.utf16), options))
    }

    static func fold(_ units: [UInt16], _ options: TextSearchOptions) -> [UInt16] {
        let stripped = options.foldDiacritics ? stripMarks(units) : units
        if options.matchCase { return stripped }
        return stripped.map { $0 == 0x130 ? 0x69 : $0.lowercasedInvariant }
    }

    static func collapse(_ text: String) -> [UInt16] {
        var units = Array(text.utf16)
        while let last = units.last, last.isWhiteSpace { units.removeLast() }
        let lead = units.prefix { $0.isWhiteSpace }.count
        var sb: [UInt16] = []
        sb.reserveCapacity(units.count)
        for c in units.dropFirst(lead) {
            if c.isWhiteSpace {
                if let last = sb.last, last != 0x20 { sb.append(0x20) }
            } else {
                sb.append(c)
            }
        }
        return sb
    }

    static func stripMarks(_ text: String) -> String {
        String(units: stripMarks(Array(text.utf16)))
    }

    static func stripMarks(_ text: [UInt16]) -> [UInt16] {
        if !text.contains(where: { $0 >= 0xC0 || $0 == 0x131 }) { return text }
        var sb: [UInt16] = []
        sb.reserveCapacity(text.count + 2)
        for c in text {
            switch c {
            case 0x131: sb.append(0x69)
            case 0x130: sb.append(0x49)
            case 0xDF: sb.append(contentsOf: [0x73, 0x73])
            case 0xE6: sb.append(contentsOf: [0x61, 0x65])
            case 0xC6: sb.append(contentsOf: [0x41, 0x45])
            case 0x153: sb.append(contentsOf: [0x6F, 0x65])
            case 0x152: sb.append(contentsOf: [0x4F, 0x45])
            case 0xF8: sb.append(0x6F)
            case 0xD8: sb.append(0x4F)
            case 0x142: sb.append(0x6C)
            case 0x141: sb.append(0x4C)
            case 0x111: sb.append(0x64)
            case 0x110: sb.append(0x44)
            default:
                // Hangul syllables and the like stay whole: decomposing them would change what a CJK search finds.
                guard c >= 0xC0 && c < 0x2E80, let scalar = Unicode.Scalar(c) else {
                    sb.append(c)
                    continue
                }
                for d in String(scalar).decomposedStringWithCanonicalMapping.utf16 where !d.isNonSpacingMark { sb.append(d) }
            }
        }
        return sb
    }
}
