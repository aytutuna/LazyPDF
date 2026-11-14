import Foundation

// Twin of windows/LazyPDF.Core/Text/TextSearch.cs: finding a query on a page or in a document. Regular expressions
// are NSRegularExpression (ICU) where the C# has .NET's Regex; the 2 second limit is held through its progress
// callback. A bad pattern throws the NSError of NSRegularExpression where the C# throws ArgumentException. The two
// dialects differ in places (PORTING.md, Known differences): ICU refuses a lookbehind of unbounded length.

/// How a search reads its query. `matchCase`: capitals must match; by default they do not matter (dotless i stays a
/// different letter from i). `wholeWord`: the match may not touch a letter or digit on either side. `regex`: the query
/// is a regular expression over the text of the page, where a line break is one space. `foldDiacritics`: accents and
/// marks do not matter, and I, dotted and dotless I and i are all the same letter.
public struct TextSearchOptions {
    public var matchCase: Bool
    public var wholeWord: Bool
    public var regex: Bool
    public var foldDiacritics: Bool

    public init(matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false, foldDiacritics: Bool = false) {
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.regex = regex
        self.foldDiacritics = foldDiacritics
    }
}

/// A hit: the page, its characters and the boxes to paint, one for each line it crosses.
public struct SearchMatch {
    public let page: Int
    public let range: TextRange
    public let text: String
    public let quads: [TextQuad]

    /// Where the hit is in the text that was searched, for a replacement that has to cut a character's own text.
    var source: HitCut? = nil
}

/// A hit in the searched text: which text (0, or 1 with line-end hyphens dropped), where it starts, and the offsets it cuts in the text of its first and last character.
struct HitCut: Equatable {
    let order: Int
    let index: Int
    let start: Int
    let end: Int
}

/// Collects the pages where a regular expression ran out of time; hits found before the limit are still given.
public final class SearchTimeouts {
    public internal(set) var pages: [Int] = []

    public init() {}
}

public enum TextSearch {
    static var regexTimeout: TimeInterval = 2

    /// Finds a query on a page. White space in the query matches any run of white space and line breaks; a hyphen at a
    /// line end can be part of the match or not (`in-` and `formation` match "information", `well-` and `known` match
    /// "well-known"). A regular expression that takes more than two seconds on a page stops there and the page is added to
    /// `timeouts`. Throws for a bad pattern, and `CancellationError` when the task is cancelled during a regular expression.
    public static func find(_ page: TextPage, _ query: String, _ options: TextSearchOptions? = nil,
                            timeouts: SearchTimeouts? = nil) throws -> [SearchMatch] {
        let options = options ?? TextSearchOptions()
        guard let matcher = try Matcher.create(query, options) else { return [] }
        return try matcher.find(page, timeouts)
    }

    /// Finds a query on the pages `first` to `last` (0-based, inclusive), one page at a time as the sequence is read, so
    /// that a viewer can show the first hits while the rest is searched. Reading it stops with `CancellationError` when
    /// the task is cancelled.
    public static func find(_ cache: TextCache, _ query: String, _ options: TextSearchOptions? = nil,
                            first: Int = 0, last: Int = Int.max, timeouts: SearchTimeouts? = nil) throws -> Hits {
        let options = options ?? TextSearchOptions()
        return Hits(cache, try Matcher.create(query, options), first, last, timeouts)
    }

    /// Every hit on a page, several in one character included (hits in a span's replacement text), for a replacement that cuts them out of that text.
    static func findAll(_ page: TextPage, _ query: String, _ options: TextSearchOptions) throws -> [SearchMatch] {
        guard let matcher = try Matcher.create(query, options) else { return [] }
        return try matcher.find(page, nil, all: true)
    }

    public struct Hits: AsyncSequence {
        public typealias Element = SearchMatch

        private let cache: TextCache
        private let matcher: Matcher?
        private let first: Int
        private let last: Int
        private let timeouts: SearchTimeouts?

        fileprivate init(_ cache: TextCache, _ matcher: Matcher?, _ first: Int, _ last: Int, _ timeouts: SearchTimeouts?) {
            self.timeouts = timeouts
            self.cache = cache
            self.matcher = matcher
            self.first = first
            self.last = last
        }

        public func makeAsyncIterator() -> Iterator {
            Iterator(Pages(cache, matcher, first, last, timeouts))
        }

        public struct Iterator: AsyncIteratorProtocol {
            private let pages: Pages

            fileprivate init(_ pages: Pages) {
                self.pages = pages
            }

            public mutating func next() async throws -> SearchMatch? {
                try pages.next()
            }
        }
    }

    fileprivate final class Pages {
        private let cache: TextCache
        private let matcher: Matcher?
        private let end: Int
        private var page: Int
        private let timeouts: SearchTimeouts?
        private var pending: [SearchMatch] = []

        init(_ cache: TextCache, _ matcher: Matcher?, _ first: Int, _ last: Int, _ timeouts: SearchTimeouts?) {
            self.timeouts = timeouts
            self.cache = cache
            self.matcher = matcher
            end = min(last, cache.pageCount - 1)
            page = max(first, 0)
        }

        func next() throws -> SearchMatch? {
            guard let matcher else { return nil }
            while pending.isEmpty {
                if page > end { return nil }
                try Task.checkCancellation()
                pending = try matcher.find(cache.get(page), timeouts)
                pending.reverse()
                page += 1
            }
            return pending.removeLast()
        }
    }

    fileprivate struct Hit {
        let range: TextRange
        let searched: SearchText
        let order: Int
        let index: Int
        let length: Int
    }

    fileprivate final class Matcher {
        private let options: TextSearchOptions
        private let query: [UInt16]
        private let regex: NSRegularExpression?

        private init(_ options: TextSearchOptions, _ query: [UInt16], _ regex: NSRegularExpression?) {
            self.options = options
            self.query = query
            self.regex = regex
        }

        static func create(_ query: String, _ options: TextSearchOptions) throws -> Matcher? {
            if query.isEmpty { return nil }
            if options.regex {
                let folded = options.foldDiacritics ? SearchText.stripMarks(query) : query
                let pattern = options.wholeWord ? "(?<![\\p{L}\\p{N}])(?:\(folded))(?![\\p{L}\\p{N}])" : folded
                let regex = try NSRegularExpression(pattern: pattern, options: options.matchCase ? [] : [.caseInsensitive])
                return Matcher(options, [], regex)
            }
            let plain = SearchText.collapse(String(units: SearchText.fold(Array(query.utf16), options)))
            return plain.isEmpty ? nil : Matcher(options, plain, nil)
        }

        func find(_ page: TextPage, _ timeouts: SearchTimeouts?, all: Bool = false) throws -> [SearchMatch] {
            var found: [Hit] = []
            let text = SearchText.build(page, options, false)
            var timedOut = try !collect(text, 0, &found)
            if text.hasHyphenBreak { timedOut = try !collect(SearchText.build(page, options, true), 1, &found) || timedOut }
            if timedOut { timeouts?.pages.append(page.pageIndex) }
            found.sort { a, b in
                if a.range.start != b.range.start { return a.range.start < b.range.start }
                if all {
                    let (x, y) = (a.searched.startOf(a.index), b.searched.startOf(b.index))
                    if x != y { return x < y }
                }
                if a.range.end != b.range.end { return b.range.end < a.range.end }
                return a.order != b.order ? a.order < b.order : a.index < b.index
            }
            var result: [SearchMatch] = []
            var end = -1
            for hit in found {
                let range = hit.range
                if !all && range.start < end { continue }
                end = range.end
                let cut = HitCut(order: hit.order, index: hit.index, start: hit.searched.startOf(hit.index), end: hit.searched.endOf(hit.index + hit.length - 1))
                result.append(SearchMatch(page: page.pageIndex, range: range, text: page.getText(range, joinHyphens: true), quads: page.quads(range), source: cut))
            }
            return result
        }

        private func collect(_ text: SearchText, _ order: Int, _ found: inout [Hit]) throws -> Bool {
            if text.text.isEmpty { return true }
            guard let regex else {
                var from = 0
                while from <= text.text.count - query.count {
                    let i = indexOf(text.text, from)
                    if i < 0 { break }
                    from = i + query.count
                    if options.wholeWord && !isWhole(text.text, i, from) {
                        from = i + 1
                        continue
                    }
                    found.append(Hit(range: TextRange(text.map[i], text.map[from - 1] + 1), searched: text, order: order, index: i, length: from - i))
                }
                return true
            }
            let string = String(units: text.text)
            var deadline = Date().addingTimeInterval(TextSearch.regexTimeout)
            var cancelled = false
            var timedOut = false
            var matched: [Hit] = []
            regex.enumerateMatches(in: string, options: [.reportProgress], range: NSRange(location: 0, length: text.text.count)) { match, flags, stop in
                if Task.isCancelled {
                    cancelled = true
                    stop.pointee = true
                    return
                }
                if flags.contains(.progress) || match == nil {
                    if Date() > deadline {
                        timedOut = true
                        stop.pointee = true
                    }
                    return
                }
                deadline = Date().addingTimeInterval(TextSearch.regexTimeout)
                guard let m = match?.range, m.length > 0, m.location >= 0, m.location + m.length <= text.map.count else { return }
                matched.append(Hit(range: TextRange(text.map[m.location], text.map[m.location + m.length - 1] + 1), searched: text, order: order, index: m.location, length: m.length))
            }
            found.append(contentsOf: matched)
            if cancelled { throw CancellationError() }
            return !timedOut
        }

        private func indexOf(_ text: [UInt16], _ from: Int) -> Int {
            let last = text.count - query.count
            var i = from
            while i <= last {
                if text[i] == query[0] {
                    var k = 1
                    while k < query.count && text[i + k] == query[k] { k += 1 }
                    if k == query.count { return i }
                }
                i += 1
            }
            return -1
        }

        // The edge of the query decides: a query that starts with a punctuation mark has no word edge there.
        private func isWhole(_ text: [UInt16], _ start: Int, _ end: Int) -> Bool {
            if let first = query.first, first.isLetterOrDigit, start > 0, text[start - 1].isLetterOrDigit { return false }
            guard let last = query.last else { return true }
            return !(last.isLetterOrDigit && end < text.count && text[end].isLetterOrDigit)
        }
    }
}
