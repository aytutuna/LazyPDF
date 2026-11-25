import Foundation

// Twin of windows/LazyPDF.Core/Ocr/PdfOcrLayer.cs: the invisible text layer that makes a scanned page searchable: the
// words in render mode 3 (ISO 32000-1 9.3.6) in a font whose only glyph draws nothing, set on the boxes where the
// recognizer found them. The layer is one content stream per page, first in /Contents and wrapped in q..Q, carrying a
// /LazyPDFOcr key; that key is what `has`, `remove` and `add` look for, so a layer by another tool is neither found nor
// removed. Changes are made to the open document in memory; the caller commits them.
//
// The ArgumentOutOfRangeException of `add` and `correct` is thrown as `ArgumentException` with the .NET message: the
// page index and the size of the picture come from the app and the renderer, not from a caller's constant.

/// The recognized words of one page and the size of the picture they were found in.
public struct OcrPageWords {
    public let pageIndex: Int
    public let words: [OcrWord]
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(_ pageIndex: Int, _ words: [OcrWord], _ pixelWidth: Int, _ pixelHeight: Int) {
        self.pageIndex = pageIndex
        self.words = words
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// A word of a page's text layer. `index` counts words from 0 in reading order; `box` is on the page as shown.
public struct OcrLayerWord {
    public let index: Int
    public let text: String
    public let box: DisplayRect

    public init(_ index: Int, _ text: String, _ box: DisplayRect) {
        self.index = index
        self.text = text
        self.box = box
    }
}

public enum PdfOcrLayer {
    /// Words past this many on a page are ignored.
    public static let maxWords = 5000

    /// Writes the layer of each page, replacing the one it has. A page whose words come to nothing ends up without a
    /// layer. One font serves all the pages of a call. Returns the words placed (empty text and boxes without area or
    /// position are left out, and words past `maxWords` on a page). Throws for a page index outside the document, or a
    /// picture size of zero, before anything changes.
    public static func add(_ document: PdfDocument, _ pages: [OcrPageWords], _ language: String) throws -> Int {
        var layouts: [(page: PdfPage, geometry: PageGeometry, lines: [[PlacedWord]])] = []
        for entry in pages {
            if entry.pageIndex < 0 || entry.pageIndex >= document.pages.count { throw outOfRange("pages") }
            if entry.pixelWidth <= 0 || entry.pixelHeight <= 0 { throw outOfRange("pages") }
            let page = document.pages[entry.pageIndex]
            let geometry = PageGeometry(page)
            layouts.append((page, geometry, OcrLayerContent.layout(entry.words, entry.pixelWidth, entry.pixelHeight, geometry)))
        }

        // Adding objects can fail (the file has no numbers left), so everything that adds one comes before the old layers go.
        let texts = layouts.flatMap { $0.lines }.flatMap { $0 }.map { $0.text }
        let codes = GlyphlessCodes.for(texts)
        var font: PdfReference?
        var streams: [PdfReference?] = []
        for layout in layouts {
            if layout.lines.isEmpty {
                streams.append(nil)
                continue
            }
            let shared = try font ?? OcrLayerContent.addFont(document, codes)
            font = shared
            let content = OcrLayerContent.build(layout.lines, layout.geometry, unitOf(layout.page), codes)
            streams.append(try OcrLayerContent.addStream(document, content, language))
        }

        for layout in layouts { _ = remove(document, layout.page) }
        var count = 0
        for (layout, stream) in zip(layouts, streams) {
            guard let stream, let font else { continue }
            privateFonts(document, layout.page, create: true)?[OcrLayerContent.fontName] = font
            var items = contents(document, layout.page)
            items.insert(stream, at: 0)
            layout.page.dictionary["Contents"] = PdfArray(items)
            count += layout.lines.reduce(0) { $0 + $1.count }
        }
        return count
    }

    /// True when the page has a layer written by `add`.
    public static func has(_ document: PdfDocument, _ page: PdfPage) -> Bool { !layerStreams(document, page).isEmpty }

    /// The language tag the layer was written with, or nil without a layer.
    public static func language(_ document: PdfDocument, _ page: PdfPage) -> String? {
        guard let stream = layerStreams(document, page).first else { return nil }
        return languageOf(document, stream)
    }

    private static func languageOf(_ document: PdfDocument, _ stream: PdfStream) -> String? {
        guard let s = document.resolve(document.dict(stream.dictionary, OcrLayerContent.key)?["Lang"]) as? PdfString else { return nil }
        return OcrLayerContent.asciiString(s.bytes)
    }

    /// Takes the layer off the page and its font out of the page's resources. Returns false when there was none.
    @discardableResult
    public static func remove(_ document: PdfDocument, _ page: PdfPage) -> Bool {
        let layers = layerStreams(document, page)
        if layers.isEmpty { return false }
        // A page copied by Duplicate shares the stream, so the object stays.
        var items = contents(document, page)
        items.removeAll { item in
            guard let s = document.resolve(item) as? PdfStream else { return false }
            return layers.contains { $0 === s }
        }
        page.dictionary["Contents"] = PdfArray(items)
        privateFonts(document, page, create: false)?.remove(OcrLayerContent.fontName)
        return true
    }

    /// The words of the layer in the order they were written, boxes on the page as shown. Empty without a layer.
    public static func words(_ document: PdfDocument, _ page: PdfPage) throws -> [OcrLayerWord] {
        let geometry = PageGeometry(page)
        var words: [OcrLayerWord] = []
        for stream in layerStreams(document, page) {
            for line in try OcrLayerContent.read(document, page, stream, geometry) {
                for word in line {
                    words.append(OcrLayerWord(words.count, word.text, bounds(word)))
                }
            }
        }
        return words
    }

    // A turned word is an upright box at its baseline start, turned by angle; the box shown covers the turned word.
    private static func bounds(_ word: PlacedWord) -> DisplayRect {
        if word.angle == 0 { return DisplayRect(word.x, word.y, word.width, word.height) }
        let c = cos(word.angle), s = sin(word.angle)
        let px = word.x, py = word.y + word.height
        let ex = word.width * c, ey = -word.width * s
        let ux = -word.height * s, uy = -word.height * c
        let xs = [0, ex, ux, ex + ux], ys = [0, ey, uy, ey + uy]
        let left = px + xs.min()!, right = px + xs.max()!
        let top = py + ys.min()!, bottom = py + ys.max()!
        return DisplayRect(left, top, right - left, bottom - top)
    }

    /// Changes the text of word `index` (as `words` numbers them); the box stays. Empty text removes the word. The font
    /// is replaced only when the text has a character beyond the BMP that the font does not carry yet. Throws when there
    /// is no such word.
    public static func correct(_ document: PdfDocument, _ page: PdfPage, _ index: Int, _ text: String) throws {
        let shown = PageGeometry(page)
        var first = 0
        for stream in layerStreams(document, page) {
            let geometry = try OcrLayerContent.writtenIn(document, page, stream, shown)
            var lines = try OcrLayerContent.read(document, page, stream, geometry)
            let count = lines.reduce(0) { $0 + $1.count }
            if index >= first + count {
                first += count
                continue
            }
            try change(&lines, index - first, OcrLayerContent.clean(text))
            try rewrite(document, page, stream, lines, geometry)
            return
        }
        throw outOfRange("index")
    }

    private static func change(_ lines: inout [[PlacedWord]], _ index: Int, _ text: String) throws {
        if index < 0 { throw outOfRange("index") }
        var index = index
        for at in 0..<lines.count {
            if index >= lines[at].count {
                index -= lines[at].count
                continue
            }
            if text.isEmpty {
                lines[at].remove(at: index)
            } else {
                let old = lines[at][index]
                lines[at][index] = PlacedWord(text, old.x, old.y, old.width, old.height, old.angle)
            }
            lines.removeAll { $0.isEmpty }
            return
        }
    }

    private static func rewrite(_ document: PdfDocument, _ page: PdfPage, _ stream: PdfStream, _ lines: [[PlacedWord]], _ geometry: PageGeometry) throws {
        let fonts = privateFonts(document, page, create: true)
        let texts = lines.flatMap { $0 }.map { $0.text }
        let known = OcrLayerContent.fontOf(document, page, OcrLayerContent.fontName).map { GlyphlessCodes.from($0) }
        // The font serves every layer stream of the page, so a replacement keeps the characters the old one had at their codes.
        let kept = (known?.supplementary ?? []).compactMap { Unicode.Scalar(UInt32(truncatingIfNeeded: $0)).map { String($0) } }
        var codes = GlyphlessCodes.for(kept + texts)
        // Codes of characters beyond the BMP depend on the font, so a font that lacks one of them is replaced.
        if let known, texts.allSatisfy({ known.covers($0) }) {
            codes = known
        } else {
            fonts?[OcrLayerContent.fontName] = try OcrLayerContent.addFont(document, codes)
        }
        // A new stream, not new data in the old one: a duplicated page shares the old stream.
        var items = contents(document, page)
        let content = OcrLayerContent.build(lines, geometry, unitOf(page), codes)
        let replacement = try OcrLayerContent.addStream(document, content, languageOf(document, stream) ?? "")
        if let at = items.firstIndex(where: { document.resolve($0) === stream }) { items[at] = replacement }
        page.dictionary["Contents"] = PdfArray(items)
    }

    private static func outOfRange(_ name: String) -> ArgumentException {
        ArgumentException("Specified argument was out of the range of valid values. (Parameter '\(name)')")
    }

    private static func unitOf(_ page: PdfPage) -> Double { page.userUnit > 0 ? page.userUnit : 1 }

    private static func contents(_ document: PdfDocument, _ page: PdfPage) -> [PdfObject] {
        let value = page.dictionary["Contents"]
        switch document.resolve(value) {
        case is PdfStream: return value.map { [$0] } ?? []
        case let array as PdfArray: return array.items
        default: return []
        }
    }

    private static func layerStreams(_ document: PdfDocument, _ page: PdfPage) -> [PdfStream] {
        contents(document, page).compactMap { document.resolve($0) as? PdfStream }.filter { $0.dictionary.containsKey(OcrLayerContent.key) }
    }

    // The page's /Font dictionary as a copy of its own, so that a resources dictionary shared between pages is left alone.
    private static func privateFonts(_ document: PdfDocument, _ page: PdfPage, create: Bool) -> PdfDictionary? {
        if !create && document.dict(page.resources, "Font")?.containsKey(OcrLayerContent.fontName) != true { return nil }
        var resources = ContentResources.forEdit(document, page)
        if page.dictionary["Resources"] is PdfReference {
            resources = resources.copy()
            page.dictionary["Resources"] = resources
        }
        let fonts = document.dict(resources, "Font")?.copy() ?? PdfDictionary()
        resources["Font"] = fonts
        return fonts
    }
}
