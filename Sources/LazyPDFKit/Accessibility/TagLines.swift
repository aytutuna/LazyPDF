import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/TagLines.cs: a line of a `TextPage` with the numbers the tagger judges it by,
// in display points.
//
// The C# uses two Regex patterns here. They are matched by hand over UTF-16 units: `\d` is a Unicode decimal digit, `\s` a
// White_Space character, and `$` also stands before a final line feed, as in .NET.

struct TagLine {
    let range: TextRange
    let rect: DisplayRect
    let size: Double
    let bold: Bool
    let text: String
    let before: TextBreak
    let isVertical: Bool

    init(range: TextRange, rect: DisplayRect, size: Double, bold: Bool, text: String, before: TextBreak, isVertical: Bool) {
        self.range = range
        self.rect = rect
        self.size = size
        self.bold = bold
        self.text = text
        self.before = before
        self.isVertical = isVertical
    }

    init(_ page: TextPage, _ source: PageLine, _ geometry: PageGeometry) {
        range = source.range
        rect = geometry.toDisplay(source.bounds)
        text = DotNetText.trim(source.text)
        before = source.before
        isVertical = source.isVertical
        // In the order the sizes were first met, as the C# Dictionary enumerates; a tie goes to the first.
        var sizes: [(size: Double, count: Int)] = []
        var sizeAt: [Double: Int] = [:]
        var boldGlyphs = 0, glyphs = 0
        for i in stride(from: source.range.start, to: source.range.end, by: 1) {
            let c = page.chars[i]
            if c.isSpace || c.text.isEmpty { continue }
            glyphs += 1
            if let font = c.font, font.isBold || font.name.lowercased().contains("black") { boldGlyphs += 1 }
            let size = (c.size * 2).rounded(.toNearestOrEven) / 2
            if let at = sizeAt[size] {
                sizes[at].count += 1
            } else {
                sizeAt[size] = sizes.count
                sizes.append((size, 1))
            }
        }
        var commonest = sizes.first
        for candidate in sizes.dropFirst() where candidate.count > (commonest?.count ?? 0) { commonest = candidate }
        size = commonest?.size ?? 0
        bold = glyphs > 0 && boldGlyphs * 2 > glyphs
    }

    /// A lone list marker and the text after it, which the layout set apart as a table cell, as one line.
    static func join(_ marker: TagLine, _ body: TagLine) -> TagLine {
        let x = min(marker.rect.x, body.rect.x), y = min(marker.rect.y, body.rect.y)
        let rect = DisplayRect(x, y, max(marker.rect.x + marker.rect.width, body.rect.x + body.rect.width) - x,
                               max(marker.rect.y + marker.rect.height, body.rect.y + body.rect.height) - y)
        return TagLine(range: TextRange(marker.range.start, body.range.end), rect: rect, size: body.size, bold: body.bold,
                       text: marker.text + " " + body.text, before: marker.before, isVertical: body.isVertical)
    }
}

struct ListMarker {
    let numbered: Bool
    let length: Int
}

enum TagText {
    private static let bullets = Array("•◦▪▫●○■□◆◇‣⁃∙·►▸➢➤✓✔➔".utf16)
    private static let romanSmall = Array("ivxIVX".utf16)
    private static let romanPage = Array("ivxlcdm".utf16)

    /// The line's text with digits folded, so that "Page 3" and "Page 4" are one thing; nil for text with no letter or digit.
    static func signature(_ text: String) -> String? {
        var folded: [UInt16] = []
        var any = false
        for unit in DotNetText.lowerInvariant(DotNetText.trim(text)).utf16 {
            if DotNetText.isDigit(unit) {
                if folded.last != 0x23 { folded.append(0x23) }
                any = true
            } else if DotNetText.isWhiteSpace(unit) {
                if let last = folded.last, last != 0x20 { folded.append(0x20) }
            } else {
                folded.append(unit)
                any = any || DotNetText.isLetter(unit)
            }
        }
        return any ? DotNetText.trim(String(decoding: folded, as: UTF16.self)) : nil
    }

    static func isPageNumber(_ text: String) -> Bool {
        var units = Array(DotNetText.trim(text).utf16)[...]
        let dashes: [UInt16] = [0x2D, 0x2013, 0x2014, 0x20]
        while let first = units.first, dashes.contains(first) { units = units.dropFirst() }
        while let last = units.last, dashes.contains(last) { units = units.dropLast() }
        return matchesPageNumber(Array(units))
    }

    /// "T" or "B" when the line is in the top or bottom tenth of the page, else nil.
    static func band(_ line: TagLine, _ pageHeight: Double) -> String? {
        let middle = line.rect.y + line.rect.height / 2
        return middle < pageHeight * 0.1 ? "T" : middle > pageHeight * 0.9 ? "B" : nil
    }

    static func isLoneMarker(_ text: String) -> Bool {
        let length = text.utf16.count
        guard length <= 5, let marker = markerOf(text + " x") else { return false }
        return marker.length == length
    }

    static func markerOf(_ text: String) -> ListMarker? {
        let units = Array(text.utf16)
        if units.count < 2 { return nil }
        let first = units[0]
        if bullets.contains(first) || (first >= 0xF000 && first <= 0xF0FF) { return ListMarker(numbered: false, length: 1) }
        if (first == 0x2D || first == 0x2013 || first == 0x2014 || first == 0x2A) && units[1] == 0x20 {
            return ListMarker(numbered: false, length: 1)
        }
        guard let length = numberedLength(units) else { return nil }
        return ListMarker(numbered: true, length: length)
    }

    // ^(\(?(\d{1,3}|[A-Za-z]|[ivxIVX]{1,5})[.)])(\s|$): the length of the group before the white space. No alternative can
    // give back characters to the next one, so each is tried once.
    private static func numberedLength(_ s: [UInt16]) -> Int? {
        var i = 0
        if i < s.count, s[i] == 0x28 { i += 1 }
        var body = 0
        let digits = run(s, i) { DotNetText.isDigit($0) }
        if digits >= 1 && digits <= 3 {
            body = digits
        } else if i < s.count, isAsciiLetter(s[i]) {
            let roman = run(s, i) { romanSmall.contains($0) }
            body = roman >= 2 && roman <= 5 ? roman : 1
        }
        let punctuation = i + body
        guard body > 0, punctuation < s.count, s[punctuation] == 0x2E || s[punctuation] == 0x29 else { return nil }
        let end = punctuation + 1
        guard end == s.count || DotNetText.isWhiteSpace(s[end]) else { return nil }
        return end
    }

    // ^(page\s*)?(\d{1,4}|[ivxlcdm]{1,6})(\s*(of|/)\s*\d{1,4})?$ without regard to case.
    private static func matchesPageNumber(_ s: [UInt16]) -> Bool {
        var i = 0
        if starts(s, i, "page") {
            i += 4
            while i < s.count, DotNetText.isWhiteSpace(s[i]) { i += 1 }
        }
        let digits = run(s, i) { DotNetText.isDigit($0) }
        if digits >= 1 && digits <= 4 {
            i += digits
        } else {
            let roman = run(s, i) { romanPage.contains(lower($0)) }
            guard roman >= 1 && roman <= 6 else { return false }
            i += roman
        }
        if atEnd(s, i) { return true }
        while i < s.count, DotNetText.isWhiteSpace(s[i]) { i += 1 }
        if starts(s, i, "of") {
            i += 2
        } else if i < s.count, s[i] == 0x2F {
            i += 1
        } else {
            return false
        }
        while i < s.count, DotNetText.isWhiteSpace(s[i]) { i += 1 }
        let more = run(s, i) { DotNetText.isDigit($0) }
        guard more >= 1 && more <= 4 else { return false }
        return atEnd(s, i + more)
    }

    private static func run(_ s: [UInt16], _ from: Int, _ test: (UInt16) -> Bool) -> Int {
        var n = 0
        while from + n < s.count, test(s[from + n]) { n += 1 }
        return n
    }

    private static func starts(_ s: [UInt16], _ at: Int, _ word: String) -> Bool {
        let letters = Array(word.utf16)
        guard at + letters.count <= s.count else { return false }
        for (k, letter) in letters.enumerated() where lower(s[at + k]) != letter { return false }
        return true
    }

    private static func lower(_ unit: UInt16) -> UInt16 {
        unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit
    }

    private static func isAsciiLetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
    }

    // $ matches at the end and before a last line feed.
    private static func atEnd(_ s: [UInt16], _ at: Int) -> Bool {
        at == s.count || (at == s.count - 1 && s[at] == 0x0A)
    }
}
