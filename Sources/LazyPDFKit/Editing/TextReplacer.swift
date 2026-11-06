import Foundation

// Twin of windows/LazyPDF.Core/Editing/TextReplacer.cs: find and replace through a whole document, committed as one
// step. Regular expressions are NSRegularExpression (ICU) as in `TextSearch`, and the expansion of $1, ${name}, $&,
// $`, $', $+ and $_ is done here, where the C# lets .NET's Match.Result do it. The numbers of groups follow .NET:
// unnamed groups first, then the named ones in order, so $1 is the same group on both sides (GroupNumbering).

/// A match that was not replaced, and why.
public struct ReplaceFailure: Equatable {
    public let page: Int
    public let text: String
    public let reason: String

    public init(page: Int, text: String, reason: String) {
        self.page = page
        self.text = text
        self.reason = reason
    }
}

/// What `TextReplacer.replaceAll` did. `replaced`: matches replaced. `failed`: matches left as they were. `pages`: pages that changed.
public struct ReplaceReport {
    public let replaced: Int
    public let failed: [ReplaceFailure]
    public let substitutions: [FontSubstitution]
    public let pages: [Int]

    public init(replaced: Int, failed: [ReplaceFailure], substitutions: [FontSubstitution], pages: [Int]) {
        self.replaced = replaced
        self.failed = failed
        self.substitutions = substitutions
        self.pages = pages
    }
}

public enum TextReplacer {
    private struct RangeKey: Hashable {
        let start: Int
        let end: Int
    }

    private static let regexTimeout: TimeInterval = 2

    /// Replaces every match of `query` (searched as `TextSearch` does, with the same options) in the document of
    /// `session` and commits once. With `TextSearchOptions.regex` the replacement may use groups ($1). A match that runs
    /// over two lines, or that no font can show, stays as it was and is reported.
    public static func replaceAll(_ session: PdfEditSession, _ query: String, _ replacement: String, _ options: TextSearchOptions? = nil,
                                  fonts: FontSource? = nil, label: String = "Replace text") throws -> ReplaceReport {
        let options = options ?? TextSearchOptions()
        let document = session.document
        var failures: [ReplaceFailure] = []
        var substitutions: [FontSubstitution] = []
        var changed: [Int] = []
        var replaced = 0
        for p in 0..<document.pages.count {
            try Task.checkCancellation()
            let model = PageModel.load(document, p)
            let matches = try TextSearch.find(model.text, query, options)
            if matches.isEmpty { continue }
            let batch = EditBatch(document, model.page, model.scan)
            let builder = TextBuilder(document, batch, fonts)
            let editor = TextEditor(model, batch, builder, fonts)
            let expanded = try expansions(model.text, query, replacement, options)
            var done: [SearchMatch] = []
            for match in matches {
                let mark = batch.save()
                do {
                    if linesOf(model, match.range) > 1 { throw EditConflictException(EditingText.crossesLines) }
                    try editor.replace(match.range, expanded[RangeKey(start: match.range.start, end: match.range.end)] ?? replacement)
                    done.append(match)
                } catch let e as EditConflictException {
                    batch.restore(mark)
                    failures.append(ReplaceFailure(page: p, text: match.text, reason: e.message))
                }
            }
            if done.isEmpty { continue }
            do {
                try batch.apply()
                builder.writeAdditions()
            } catch let e as EditConflictException {
                batch.discard()
                failures.append(contentsOf: done.map { ReplaceFailure(page: p, text: $0.text, reason: e.message) })
                continue
            }
            replaced += done.count
            changed.append(p)
            substitutions.append(contentsOf: builder.substitutions)
        }
        if replaced > 0 { try session.commit(label) }
        return ReplaceReport(replaced: replaced, failed: failures, substitutions: substitutions, pages: changed)
    }

    private static func linesOf(_ model: PageModel, _ range: TextRange) -> Int {
        var lines = Set<Int>()
        var i = Swift.max(range.start, 0)
        let end = Swift.min(range.end, model.charGlyphs.count)
        while i < end {
            if model.charGlyphs[i] != nil { lines.insert(model.text.chars[i].line) }
            i += 1
        }
        return lines.count
    }

    // The replacement of each regex match, found on the text TextSearch runs (folded as the options ask) so that every
    // match it reports has an entry. Lookarounds and the whole-word edges see the page; a group is the page's own text,
    // with its case and accents, taken back through the map.
    private static func expansions(_ text: TextPage, _ query: String, _ replacement: String, _ options: TextSearchOptions) throws -> [RangeKey: String] {
        var found: [RangeKey: String] = [:]
        if !options.regex { return found }
        let folded = options.foldDiacritics ? SearchText.stripMarks(query) : query
        let pattern = options.wholeWord ? "(?<![\\p{L}\\p{N}])(?:\(folded))(?![\\p{L}\\p{N}])" : folded
        let regex = try NSRegularExpression(pattern: pattern, options: options.matchCase ? [] : [.caseInsensitive])
        let numbering = GroupNumbering(pattern)
        for dropHyphens in [false, true] {
            let searched = SearchText.build(text, options, dropHyphens)
            var matches: [NSTextCheckingResult] = []
            var timedOut = false
            var deadline = Date().addingTimeInterval(regexTimeout)
            regex.enumerateMatches(in: String(units: searched.text), options: [.reportProgress], range: NSRange(location: 0, length: searched.text.count)) { match, flags, stop in
                if flags.contains(.progress) || match == nil {
                    if Date() > deadline {
                        timedOut = true
                        stop.pointee = true
                    }
                    return
                }
                deadline = Date().addingTimeInterval(regexTimeout)
                if let match { matches.append(match) }
            }
            for m in matches where m.range.length > 0 && m.range.location >= 0 && m.range.location + m.range.length <= searched.text.count {
                let key = rangeOf(searched, m.range.location, m.range.length)
                let at = RangeKey(start: key.start, end: key.end)
                if found[at] == nil { found[at] = expand(text, searched, numbering, m, replacement) }
            }
            if timedOut || !searched.hasHyphenBreak { break }
        }
        return found
    }

    private static func rangeOf(_ searched: SearchText, _ index: Int, _ length: Int) -> TextRange {
        TextRange(searched.map[index], searched.map[index + length - 1] + 1)
    }

    // The tokens .NET expands from the searched text ($&, $+, $`, $', $_) are taken from the page as well; $$ is left for the last step.
    private static func expand(_ text: TextPage, _ searched: SearchText, _ numbering: GroupNumbering, _ m: NSTextCheckingResult, _ replacement: String) -> String {
        let all = searched.text
        // The page text of a range loses the white space at its ends, which a group or the text around a match may be made of.
        func page(_ index: Int, _ length: Int) -> [UInt16] {
            if length == 0 { return [] }
            let seen = Array(all[index..<index + length])
            let core = Array(text.getText(rangeOf(searched, index, length), joinHyphens: true).utf16)
            let lead = seen.prefix { $0.isWhiteSpace }.count
            var trail: [UInt16] = []
            if lead < seen.count {
                var end = seen.count
                while end > 0 && seen[end - 1].isWhiteSpace { end -= 1 }
                trail = Array(seen[end...])
            }
            var result: [UInt16] = []
            for unit in Array(seen[..<lead]) + core + trail {
                result.append(unit)
                if unit == 0x24 { result.append(unit) }
            }
            return result
        }
        func group(_ icu: Int) -> [UInt16] {
            if icu >= m.numberOfRanges { return [] }
            let range = m.range(at: icu)
            return range.location == NSNotFound ? [] : page(range.location, range.length)
        }

        let r = Array(replacement.utf16)
        var out: [UInt16] = []
        var i = 0
        while i < r.count {
            if r[i] != 0x24 || i + 1 == r.count {
                out.append(r[i])
                i += 1
                continue
            }
            let c = r[i + 1]
            var length = 0
            var name: String?
            if c == 0x24 {
                out.append(contentsOf: [0x24, 0x24])
                i += 2
                continue
            } else if c == 0x26 {
                length = 2
                name = "0"
            } else if c == 0x60 || c == 0x27 || c == 0x2B || c == 0x5F {
                length = 2
                if c == 0x2B { name = String(numbering.total) }
            } else if isDecimalDigit(c) {
                var e = i + 1
                while e < r.count && isDecimalDigit(r[e]) { e += 1 }
                length = e - i
                name = String(units: Array(r[(i + 1)..<e]))
            } else if c == 0x7B {
                var e = i + 2
                while e < r.count && isWordChar(r[e]) { e += 1 }
                if e > i + 2 && e < r.count && r[e] == 0x7D {
                    length = e + 1 - i
                    name = String(units: Array(r[(i + 2)..<e]))
                }
            }
            if length == 0 {
                out.append(0x24)
                i += 1
                continue
            }
            let token = Array(r[i..<i + length])
            i += length
            if name == nil {
                switch c {
                case 0x60: out.append(contentsOf: page(0, m.range.location))
                case 0x27: out.append(contentsOf: page(m.range.location + m.range.length, all.count - m.range.location - m.range.length))
                default: out.append(contentsOf: page(0, all.count))
                }
                continue
            }
            guard let key = name, let icu = numbering.index(of: key) else {
                out.append(contentsOf: token)
                continue
            }
            out.append(contentsOf: group(icu))
        }
        // What is left of Match.Result: $$ is one $.
        var result: [UInt16] = []
        var k = 0
        while k < out.count {
            result.append(out[k])
            k += out[k] == 0x24 && k + 1 < out.count && out[k + 1] == 0x24 ? 2 : 1
        }
        return String(units: result)
    }

    private static func isDecimalDigit(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit)?.properties.generalCategory == .decimalNumber
    }

    // \w: letters, marks that do not space, decimal digits and connector punctuation.
    private static func isWordChar(_ unit: UInt16) -> Bool {
        switch Unicode.Scalar(unit)?.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .nonspacingMark, .decimalNumber, .connectorPunctuation:
            return true
        default:
            return false
        }
    }
}

/// Which capture group of ICU is group n of .NET: unnamed groups are 1 to k in order and the named ones follow, in order,
/// where ICU counts every group from the left.
struct GroupNumbering {
    private var byNumber: [Int] = []
    private var byName: [String: Int] = [:]

    init(_ pattern: String) {
        let p = Array(pattern.unicodeScalars)
        var unnamed: [Int] = []
        var named: [(name: String, icu: Int)] = []
        var icu = 0
        var depth = 0
        var i = 0
        while i < p.count {
            let c = p[i]
            if c == "\\" {
                i += 2
                continue
            }
            if depth > 0 {
                if c == "[" {
                    depth += 1
                } else if c == "]" {
                    depth -= 1
                }
                i += 1
                continue
            }
            if c == "[" {
                depth = 1
                i += 1
                if i < p.count && p[i] == "^" { i += 1 }
                if i < p.count && p[i] == "]" { i += 1 }
                continue
            }
            if c == "(" {
                if i + 1 < p.count && p[i + 1] == "?" {
                    let kind: Unicode.Scalar? = i + 2 < p.count ? p[i + 2] : nil
                    let next: Unicode.Scalar? = i + 3 < p.count ? p[i + 3] : nil
                    if i + 3 <= p.count && ((kind == "<" && next != "=" && next != "!") || kind == "'") {
                        let end: Unicode.Scalar = kind == "<" ? ">" : "'"
                        var e = i + 3
                        while e < p.count && p[e] != end { e += 1 }
                        icu += 1
                        named.append((String(String.UnicodeScalarView(p[(i + 3)..<e])), icu))
                    }
                } else {
                    icu += 1
                    unnamed.append(icu)
                }
            }
            i += 1
        }
        byNumber = unnamed + named.map { $0.icu }
        for entry in named where byName[entry.name] == nil { byName[entry.name] = entry.icu }
    }

    /// The highest group number: the group `$+` stands for.
    var total: Int { byNumber.count }

    func index(of key: String) -> Int? {
        if key.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) {
            guard let number = Int(key) else { return nil }
            if number == 0 { return 0 }
            return number <= byNumber.count ? byNumber[number - 1] : nil
        }
        return byName[key]
    }
}
