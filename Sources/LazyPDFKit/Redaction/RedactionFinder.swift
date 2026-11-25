import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionFinder.cs: finds what to redact by its shape, through `TextSearch`. Nothing
// is marked or removed.
//
// The C# searches a TextCache as an IEnumerable; `TextSearch.find` over a cache is an async sequence here, so the pages are
// searched one by one in the same order. A bad pattern is the NSError of NSRegularExpression there and an `ArgumentException`
// here, as in the C#.

public enum RedactionKind {
    case email
    case phone
    case usSocialSecurity
    case turkishId
    case iban
    case paymentCard
    case date
    case pattern
    case word
}

public enum RedactionValueSource {
    /// The /Contents of an annotation (a comment, a free text box, a popup).
    case comment

    /// The value of a text field or an editable combo box.
    case field
}

/// A hit in a value that is not page text. `annotation` is the index among the annotations of the page, as
/// `PdfAnnotations.read` lists them; for a field it is the field's first widget. `start` and `length` are in UTF-16 units of
/// the value's text, as in the C#.
public struct RedactionValueMatch {
    public let page: Int
    public let annotation: Int
    public let source: RedactionValueSource
    public var start: Int
    public let length: Int
    public let text: String
    public let kind: RedactionKind

    public init(_ page: Int, _ annotation: Int, _ source: RedactionValueSource, _ start: Int, _ length: Int, _ text: String, _ kind: RedactionKind) {
        self.page = page
        self.annotation = annotation
        self.source = source
        self.start = start
        self.length = length
        self.text = text
        self.kind = kind
    }
}

/// A hit of a finder: the mark it proposes and the text it found, for a list the user goes through before applying.
public struct RedactionMatch {
    public let mark: RedactionMark
    public let text: String
    public let kind: RedactionKind

    public init(_ mark: RedactionMark, _ text: String, _ kind: RedactionKind) {
        self.mark = mark
        self.text = text
        self.kind = kind
    }
}

public enum RedactionFinder {
    private static let months =
        "Ocak|Şubat|Mart|Nisan|Mayıs|Haziran|Temmuz|Ağustos|Eylül|Ekim|Kasım|Aralık|January|February|March|April|May|June|July|August|September|October|November|December"

    private struct Shape {
        let pattern: String
        let matchCase: Bool
        let check: ((String) -> Bool)?
        let shortest: Int

        init(_ pattern: String, _ matchCase: Bool, _ check: ((String) -> Bool)? = nil, _ shortest: Int = 0) {
            self.pattern = pattern
            self.matchCase = matchCase
            self.check = check
            self.shortest = shortest
        }
    }

    private static func shape(_ kind: RedactionKind) -> Shape? {
        switch kind {
        case .email:
            return Shape(#"[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}\-]+(?:\.[\p{L}\p{N}\-]+)*\.\p{L}{2,}"#, false)
        case .phone:
            return Shape(#"(?<![\p{N}])(?:\+\d{1,3}[ .\-]?)?(?:\(\d{2,4}\)[ .\-]?)?\d{2,4}(?:[ .\-]\d{2,4}){1,4}(?![\p{N}])"#, false, isPhone)
        case .usSocialSecurity:
            return Shape(#"(?<!\d)\d{3}[- ]\d{2}[- ]\d{4}(?!\d)"#, false, isSocialSecurity)
        case .turkishId:
            return Shape(#"(?<!\d)[1-9]\d{10}(?!\d)"#, false, isTurkishId)
        case .iban:
            return Shape(#"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?(?![A-Za-z0-9])"#, true, isIban, 15)
        case .paymentCard:
            return Shape(#"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#, false, isCard)
        case .date:
            return Shape(#"(?<!\d)(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{4}|\d{1,2}\s+(?:"# + months + #")\s+\d{4}|(?:"# + months + #")\s+\d{1,2},?\s+\d{4})(?!\d)"#, false, isDate)
        case .pattern, .word:
            return nil
        }
    }

    public static func find(_ document: PdfDocument, _ kind: RedactionKind) throws -> [RedactionMatch] {
        try find(TextCache(document), kind)
    }

    /// Everything of one built-in kind in the document. `RedactionKind.pattern` and `RedactionKind.word` have their own methods.
    public static func find(_ cache: TextCache, _ kind: RedactionKind, timeouts: SearchTimeouts? = nil) throws -> [RedactionMatch] {
        guard let shape = shape(kind) else { throw ArgumentException("Specified argument was out of the range of valid values. (Parameter 'kind')") }
        var found: [RedactionMatch] = []
        let options = TextSearchOptions(matchCase: shape.matchCase, regex: true)
        for hit in try search(cache, shape.pattern, options, timeouts) {
            if shape.check == nil || shape.check?(hit.text) == true {
                found.append(RedactionMatch(RedactionMark.fromMatch(hit), hit.text, kind))
            } else if let inner = narrow(cache.get(hit.page), hit, shape) {
                found.append(RedactionMatch(RedactionMark.fromMatch(inner), inner.text, kind))
            }
        }
        return found
    }

    /// Every hit of a regular expression (see `TextSearch` for how it reads the page). A bad pattern is an `ArgumentException`.
    public static func findRegex(_ cache: TextCache, _ pattern: String, _ matchCase: Bool = false,
                                  timeouts: SearchTimeouts? = nil) throws -> [RedactionMatch] {
        try search(cache, pattern, TextSearchOptions(matchCase: matchCase, regex: true), timeouts)
            .map { RedactionMatch(RedactionMark.fromMatch($0), $0.text, .pattern) }
    }

    public static func findWords(_ cache: TextCache, _ words: [String], _ wholeWord: Bool = true, _ matchCase: Bool = false,
                                  timeouts: SearchTimeouts? = nil) throws -> [RedactionMatch] {
        let options = TextSearchOptions(matchCase: matchCase, wholeWord: wholeWord)
        var seen = Set<OrdinalString>()
        var hits: [SearchMatch] = []
        for word in words where !word.isEmpty && seen.insert(OrdinalString(word)).inserted {
            hits.append(contentsOf: try search(cache, word, options, timeouts))
        }
        // OrderBy and ThenBy are stable.
        let ordered = hits.enumerated().sorted { a, b in
            (a.element.page, a.element.range.start, a.offset) < (b.element.page, b.element.range.start, b.offset)
        }
        return ordered.map { RedactionMatch(RedactionMark.fromMatch($0.element), $0.element.text, .word) }
    }

    /// Everything of one built-in kind in the annotation contents and field values.
    public static func findInValues(_ document: PdfDocument, _ kind: RedactionKind) throws -> [RedactionValueMatch] {
        guard let shape = shape(kind) else { throw ArgumentException("Specified argument was out of the range of valid values. (Parameter 'kind')") }
        return try inValues(document, kind, shape.pattern, shape.matchCase, shape)
    }

    /// A regular expression over the annotation contents and field values. A bad pattern is an `ArgumentException`.
    public static func findRegexInValues(_ document: PdfDocument, _ pattern: String, _ matchCase: Bool = false) throws -> [RedactionValueMatch] {
        try inValues(document, .pattern, pattern, matchCase, nil)
    }

    public static func findWordsInValues(_ document: PdfDocument, _ words: [String], _ wholeWord: Bool = true, _ matchCase: Bool = false) throws -> [RedactionValueMatch] {
        var seen = Set<OrdinalString>()
        var escaped: [String] = []
        for word in words where !word.isEmpty && seen.insert(OrdinalString(word)).inserted {
            escaped.append(NSRegularExpression.escapedPattern(for: word))
        }
        if escaped.isEmpty { return [] }
        escaped.sort { $0.utf16.count > $1.utf16.count }
        var pattern = "(?:\(escaped.joined(separator: "|")))"
        if wholeWord { pattern = "(?<![\\p{L}\\p{N}])\(pattern)(?![\\p{L}\\p{N}])" }
        return try inValues(document, .word, pattern, matchCase, nil)
    }

    private static func inValues(_ document: PdfDocument, _ kind: RedactionKind, _ pattern: String, _ matchCase: Bool, _ shape: Shape?) throws -> [RedactionValueMatch] {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
        } catch {
            throw ArgumentException("\(error)")
        }
        var found: [RedactionValueMatch] = []
        for value in RedactionValues.read(document) {
            try Task.checkCancellation()
            let ns = value.text as NSString
            for hit in regex.matches(in: value.text, range: NSRange(location: 0, length: ns.length)) where hit.range.length > 0 {
                var length = hit.range.length
                let matched = ns.substring(with: hit.range)
                if let shape, let check = shape.check, !check(matched) {
                    guard let cut = cutBack(matched, shape) else { continue }
                    length = cut
                }
                let range = NSRange(location: hit.range.location, length: length)
                found.append(RedactionValueMatch(value.page, value.annotation, value.source, range.location, length, ns.substring(with: range), kind))
            }
        }
        return found
    }

    // The same cut as `narrow`, over a plain string.
    private static func cutBack(_ text: String, _ shape: Shape) -> Int? {
        guard let check = shape.check else { return nil }
        let units = Array(text.utf16)
        var end = units.count - 1
        while end >= shape.shortest && shape.shortest > 0 {
            defer { end -= 1 }
            if units[end] == 0x20 && check(String(units: Array(units[..<end]))) { return end }
        }
        return nil
    }

    private static func search(_ cache: TextCache, _ query: String, _ options: TextSearchOptions,
                               _ timeouts: SearchTimeouts?) throws -> [SearchMatch] {
        var found: [SearchMatch] = []
        do {
            for index in 0..<cache.pageCount { found.append(contentsOf: try TextSearch.find(cache.get(index), query, options, timeouts: timeouts)) }
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            if options.regex { throw ArgumentException("\(error)") }
            throw error
        }
        return found
    }

    // An IBAN followed by an upper case word reads as a longer one; it is cut back to the longest
    // part, ending where a word ends, that passes its check.
    private static func narrow(_ page: TextPage, _ hit: SearchMatch, _ shape: Shape) -> SearchMatch? {
        guard let check = shape.check else { return nil }
        var end = hit.range.end - 1
        while end - hit.range.start >= shape.shortest && shape.shortest > 0 {
            defer { end -= 1 }
            if end < 0 || end >= page.chars.count || !page.chars[end].isSpace { continue }
            let range = TextRange(hit.range.start, end)
            let text = page.getText(range)
            if check(text) { return SearchMatch(page: hit.page, range: range, text: text, quads: page.quads(range)) }
        }
        return nil
    }

    private static func digits(_ text: String) -> [Int] {
        text.utf16.filter { $0 >= 0x30 && $0 <= 0x39 }.map { Int($0) - 0x30 }
    }

    private static func isPhone(_ text: String) -> Bool {
        let count = digits(text).count
        return count >= 9 && count <= 15
    }

    private static func isSocialSecurity(_ text: String) -> Bool {
        let d = digits(text)
        if d.count != 9 { return false }
        let area = d[0] * 100 + d[1] * 10 + d[2]
        return area != 0 && area != 666 && area < 900 && !(d[3] == 0 && d[4] == 0) && !(d[5] == 0 && d[6] == 0 && d[7] == 0 && d[8] == 0)
    }

    // 10th digit: ((odd digits sum * 7) - even digits sum) mod 10; 11th: sum of the first ten mod 10.
    private static func isTurkishId(_ text: String) -> Bool {
        let units = Array(text.utf16)
        if units.count != 11 || !units.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) || units[0] == 0x30 { return false }
        let d = units.map { Int($0) - 0x30 }
        let odd = d[0] + d[2] + d[4] + d[6] + d[8], even = d[1] + d[3] + d[5] + d[7]
        return ((odd * 7 - even) % 10 + 10) % 10 == d[9] && d[0..<10].reduce(0, +) % 10 == d[10]
    }

    // ISO 13616: move the first four characters to the end, letters become 10 to 35, the number mod 97 is 1.
    private static func isIban(_ text: String) -> Bool {
        let s = text.utf16.filter { $0 != 0x20 }
        let isAscii: (UInt16) -> Bool = { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }
        if s.count < 15 || s.count > 34 || !s.allSatisfy(isAscii) { return false }
        var remainder = 0
        for c in s[4...] + s[..<4] {
            let value = c >= 0x30 && c <= 0x39 ? Int(c) - 0x30 : Int(c & ~0x20) - 0x41 + 10
            remainder = (value > 9 ? remainder * 100 + value : remainder * 10 + value) % 97
        }
        return remainder == 1
    }

    private static func isCard(_ text: String) -> Bool {
        let d = digits(text)
        if d.count < 13 || d.count > 19 { return false }
        var sum = 0
        for i in 0..<d.count {
            var n = d[d.count - 1 - i]
            if i % 2 == 1 {
                n *= 2
                if n > 9 { n -= 9 }
            }
            sum += n
        }
        return sum % 10 == 0
    }

    private static func isDate(_ text: String) -> Bool {
        let parts = text.utf16.split(whereSeparator: { $0 == 0x2D || $0 == 0x2F || $0 == 0x2E }).map { Array($0) }
        if parts.count != 3 || !parts.allSatisfy({ $0.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }) { return true }
        let n = parts.map { $0.reduce(0) { $0 * 10 + Int($1) - 0x30 } }
        if parts[0].count == 4 { return n[1] >= 1 && n[1] <= 12 && n[2] >= 1 && n[2] <= 31 }
        return (n[0] >= 1 && n[0] <= 12 && n[1] >= 1 && n[1] <= 31) || (n[0] >= 1 && n[0] <= 31 && n[1] >= 1 && n[1] <= 12)
    }
}
