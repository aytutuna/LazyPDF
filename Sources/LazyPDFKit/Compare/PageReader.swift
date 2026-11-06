import Foundation

// Twin of windows/LazyPDF.Core/Compare/PageReader.cs: reads the pages of one file as `PageData` and finds the pictures
// on them. The words of a page that take part in a comparison are ids shared by both files.

struct PageImage {
    let hash: String
    let bounds: PdfRect
}

/// What the C# gets from `ReferenceEqualityComparer`: a dictionary key that is the stream itself.
struct StreamKey: Hashable {
    let stream: PdfStream

    init(_ stream: PdfStream) {
        self.stream = stream
    }

    static func == (a: StreamKey, b: StreamKey) -> Bool { a.stream === b.stream }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(stream)) }
}

/// String comparisons as .NET makes them with `StringComparison.Ordinal`, `OrdinalIgnoreCase` and `ToLowerInvariant`: by
/// UTF-16 unit and by simple case mapping, where Swift's `==` takes canonically equivalent text as equal and `lowercased()`
/// maps a character to several.
enum Ordinal {
    static func equal(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }

    // The dotted capital I keeps its case under the invariant culture.
    private static func mapped(_ text: String, _ map: (Unicode.Scalar) -> String) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            let other = map(scalar).unicodeScalars
            if scalar.value != 0x130, scalar.value != 0x131, other.count == 1, let one = other.first {
                result.append(one)
            } else {
                result.append(scalar)
            }
        }
        return result
    }

    static func lower(_ text: String) -> String {
        let lowered: (Unicode.Scalar) -> String = { $0.properties.lowercaseMapping }
        return String(String.UnicodeScalarView(mapped(text, lowered)))
    }

    static func equalIgnoringCase(_ a: String, _ b: String) -> Bool {
        let upper: (Unicode.Scalar) -> String = { $0.properties.uppercaseMapping }
        return mapped(a, upper) == mapped(b, upper)
    }
}

/// The ids of the words, the same word having the same id in both files.
final class TokenIds {
    private var ids: [[UInt16]: Int] = [:]

    func id(_ token: String) -> Int {
        let key = Array(token.utf16)
        if let known = ids[key] { return known }
        let id = ids.count
        ids[key] = id
        return id
    }
}

final class PageData {
    let page: PdfPage
    let text: TextPage

    /// Indexes into `TextPage.words` of the words that count.
    let kept: [Int]
    let ids: [Int]

    init(_ page: PdfPage, _ text: TextPage, _ kept: [Int], _ ids: [Int]) {
        self.page = page
        self.text = text
        self.kept = kept
        self.ids = ids
    }

    func word(_ token: Int) -> String { text.words[kept[token]].text }

    func words(_ from: Int, _ count: Int) -> String { (from..<from + count).map(word).joined(separator: " ") }

    /// The boxes of tokens `[from, from + count)`, one for each stretch of a line.
    func quads(_ from: Int, _ count: Int) -> [TextQuad] {
        var quads: [TextQuad] = []
        var k = from
        while k < from + count {
            var last = k
            while last + 1 < from + count && kept[last + 1] == kept[last] + 1 { last += 1 }
            quads.append(contentsOf: text.quads(TextRange(text.words[kept[k]].range.start, text.words[kept[last]].range.end)))
            k = last + 1
        }
        return quads
    }

    /// A quad of zero width at the place before token `at`: the end of the word before it, else the start of the one at it
    /// (the right edge in a left-to-right line, the left in a right-to-left one).
    func anchor(_ at: Int) -> [TextQuad] {
        if at > 0, let q = quads(at - 1, 1).last {
            return endsOnLeft(at) ? Self.left(q) : Self.right(q)
        }
        if at < kept.count, let q = quads(at, 1).first {
            return rightToLeft(text.chars[text.words[kept[at]].range.start]) ? Self.right(q) : Self.left(q)
        }
        return []
    }

    // Between two words of one run the run's direction decides, as with Latin words in a right-to-left line or Hebrew in a
    // left-to-right one; at a change of run, or at the end of the line, the line's: a number in a right-to-left line is
    // followed by what stands on its left.
    private func endsOnLeft(_ at: Int) -> Bool {
        let last = text.chars[text.words[kept[at - 1]].range.end - 1]
        if at < kept.count {
            let next = text.chars[text.words[kept[at]].range.start]
            if next.line == last.line && next.isRtl == last.isRtl { return last.isRtl }
        }
        return rightToLeft(last)
    }

    private func rightToLeft(_ c: TextChar) -> Bool { text.lines[c.line].isRtl }

    private static func left(_ q: TextQuad) -> [TextQuad] { [TextQuad(q.x0, q.y0, q.x0, q.y0, q.x3, q.y3, q.x3, q.y3)] }

    private static func right(_ q: TextQuad) -> [TextQuad] { [TextQuad(q.x1, q.y1, q.x1, q.y1, q.x2, q.y2, q.x2, q.y2)] }

    func formatChar(_ token: Int) -> TextChar { text.chars[text.words[kept[token]].range.start] }
}

final class PageReader {
    private static let zoneFraction = 0.07
    private static let maxImages = 10_000

    let document: PdfDocument
    private let options: CompareOptions
    private let ids: TokenIds
    private let cache: TextCache
    private let interpreter: ContentInterpreter
    private var hashes: [StreamKey: String] = [:]
    private let look: ImageLook

    init(_ document: PdfDocument, _ options: CompareOptions, _ ids: TokenIds) {
        self.document = document
        self.options = options
        self.ids = ids
        cache = TextCache(document)
        interpreter = ContentInterpreter(document)
        look = ImageLook(document)
    }

    var count: Int { document.pages.count }

    func load(_ index: Int) -> PageData {
        let page = document.pages[index]
        let text = cache.get(index)
        let geometry = options.ignoreHeaderFooter ? PageGeometry(page) : nil
        var kept: [Int] = []
        var tokens: [Int] = []
        for w in 0..<text.words.count {
            let word = text.words[w]
            if word.text.isEmpty { continue }
            if let geometry {
                let centre = geometry.toDisplay((word.bounds.left + word.bounds.right) / 2, (word.bounds.bottom + word.bounds.top) / 2)
                if centre.y < geometry.height * Self.zoneFraction || centre.y > geometry.height * (1 - Self.zoneFraction) { continue }
            }
            kept.append(w)
            tokens.append(ids.id(options.ignoreCase ? Ordinal.lower(word.text) : word.text))
        }
        return PageData(page, text, kept, tokens)
    }

    func images(_ page: PdfPage) throws -> [PageImage] {
        let collector = ImageCollector()
        interpreter.run(page, collector)
        return try collector.found.map { PageImage(hash: try hash($0), bounds: $0.bounds) }
    }

    private func hash(_ image: ImageInfo) throws -> String {
        let data: [UInt8]
        if let stream = image.stream {
            if let known = hashes[StreamKey(stream)] { return known }
            data = document.rawData(stream)
        } else {
            data = image.inline?.data ?? []
        }
        let described = try look.of(image.dictionary)
        let text = "\(image.width)x\(image.height):\(ImageLook.fingerprint(data))\(described)"
        if let stream = image.stream { hashes[StreamKey(stream)] = text }
        return text
    }

    // The pictures are read here and given their hash afterwards: the hash can be cancelled, a visitor cannot.
    private final class ImageCollector: ContentVisitor {
        var found: [ImageInfo] = []

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
            if found.count < PageReader.maxImages && image.bounds.width >= 1 && image.bounds.height >= 1 { found.append(image) }
        }
    }
}
