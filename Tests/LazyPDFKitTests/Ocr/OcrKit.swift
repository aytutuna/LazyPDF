import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Ocr/OcrKit.cs: the fake recognizer and renderer, and the pages the OCR tests read. The
// C# PigText (PdfPig reading a file back) has no twin.

/// Returns the same words for every page, or what `words` says for the page's call number.
final class FakeRecognizer: TextRecognizer {
    private let words: (Int) -> [OcrWord]
    var calls: [(width: Int, height: Int, language: String)] = []
    var before: ((Int) async throws -> Void)?

    init(_ words: @escaping (Int) -> [OcrWord]) {
        self.words = words
    }

    convenience init(_ same: [OcrWord]) {
        self.init { _ in same }
    }

    func recognizeAsync(_ image: PdfRgbaImage, _ language: String) async throws -> [OcrWord] {
        calls.append((image.width, image.height, language))
        if let before { try await before(calls.count - 1) }
        return words(calls.count - 1)
    }
}

/// Draws blank pictures of the right size for the page as shown, none over 2000 pixels on a side.
final class FakeRenderer: PageRenderer {
    private let document: PdfDocument
    private let unrenderable: [Int]
    var calls: [(page: Int, dpi: Double)] = []

    init(_ document: PdfDocument, _ unrenderable: Int...) {
        self.document = document
        self.unrenderable = unrenderable
    }

    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
        calls.append((pageIndex, dpi))
        if unrenderable.contains(pageIndex) { return nil }
        let geometry = PageGeometry(document.pages[pageIndex])
        let scale = min(dpi / 72, 2000 / max(geometry.width, geometry.height))
        let width = max(1, Int((geometry.width * scale).rounded(.toNearestOrEven)))
        let height = max(1, Int((geometry.height * scale).rounded(.toNearestOrEven)))
        return PdfRgbaImage(width, height, [UInt8](repeating: 0, count: width * height * 4))
    }
}

enum OcrKit {
    static let helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"

    static let fullPage = "q 400 0 0 600 0 0 cm /Im1 Do Q"

    /// Four words on two lines, in pixels of a picture drawn at `dpi` of a page shown 400 points wide: the boxes in points
    /// are (40,100,100,24) (160,100,110,24) (40,160,120,24) (180,160,60,24).
    static func words(dpi: Double = 72) -> [OcrWord] {
        let k = dpi / 72
        func w(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> OcrWord {
            OcrWord(text, OcrBox(x * k, y * k, width * k, height * k), 0.9)
        }
        return [w("Hello", 40, 100, 100, 24), w("world", 160, 100, 110, 24), w("Second", 40, 160, 120, 24), w("line", 180, 160, 60, 24)]
    }

    static let wordBoxes: [(text: String, x: Double, y: Double, width: Double, height: Double)] =
        [("Hello", 40, 100, 100, 24), ("world", 160, 100, 110, 24), ("Second", 40, 160, 120, 24), ("line", 180, 160, 60, 24)]

    /// A document of `count` pages, 400 by 600 points. Each draws `content` (a full-page picture by default) and has the
    /// picture as /Im1 and Helvetica as /F1; `pageEntries` goes into every page.
    static func scanBytes(_ count: Int = 1, _ pageEntries: String = "", _ content: String = fullPage) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = (0..<count).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(count) /MediaBox [0 0 400 600]>>")
        let image = 3 + 2 * count
        for i in 0..<count {
            pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(3 + count + i) 0 R /Resources <</XObject <</Im1 \(image) 0 R>> /Font <</F1 \(image + 1) 0 R>>>> \(pageEntries)>>")
        }
        for i in 0..<count { pdf.stream(3 + count + i, "", content) }
        pdf.stream(image, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0x20, 0x80, 0xC0, 0xF0])
        pdf.obj(image + 1, helvetica)
        return pdf.finish()
    }

    static func scan(_ count: Int = 1, _ pageEntries: String = "", _ content: String = fullPage) throws -> PdfDocument {
        try PdfDocument.open(scanBytes(count, pageEntries, content))
    }

    /// Pages whose content is given, 400 by 600, with Helvetica as /F1.
    static func pages(_ contents: String...) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = contents.indices.map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(contents.count) /MediaBox [0 0 400 600]>>")
        let font = 3 + 2 * contents.count
        for i in contents.indices {
            pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(3 + contents.count + i) 0 R /Resources <</Font <</F1 \(font) 0 R>>>>>>")
        }
        for i in contents.indices { pdf.stream(3 + contents.count + i, "", contents[i]) }
        pdf.obj(font, helvetica)
        return try PdfDocument.open(pdf.finish())
    }

    static func word(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> OcrWord {
        OcrWord(text, OcrBox(x, y, w, h))
    }

    /// The words of the page and where they sit on the page as shown.
    static func located(_ document: PdfDocument, _ pageIndex: Int = 0) -> [(text: String, box: DisplayRect)] {
        let page = document.pages[pageIndex]
        let geometry = PageGeometry(page)
        return TextPage.create(document, page).words.map { ($0.text, geometry.toDisplay($0.bounds)) }
    }

    static func assertAtBoxes(_ document: PdfDocument, _ pageIndex: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        let found = located(document, pageIndex)
        XCTAssertEqual(wordBoxes.map { $0.text }, found.map { $0.text }, file: file, line: line)
        for i in 0..<min(wordBoxes.count, found.count) {
            let wanted = wordBoxes[i]
            let box = found[i].box
            XCTAssertTrue(abs(box.x - wanted.x) < 1 && abs(box.y - wanted.y) < 1 && abs(box.width - wanted.width) < 1 && abs(box.height - wanted.height) < 1,
                          "\(found[i].text) is at \(box), wanted (\(wanted.x), \(wanted.y), \(wanted.width), \(wanted.height))", file: file, line: line)
        }
    }

    static func layerStreams(_ document: PdfDocument, _ pageIndex: Int = 0) -> Int {
        let page = document.pages[pageIndex]
        let contents = document.resolve(page.dictionary["Contents"])
        let items: [PdfObject] = (contents as? PdfArray)?.items ?? page.dictionary["Contents"].map { [$0] } ?? []
        return items.filter { (document.resolve($0) as? PdfStream)?.dictionary.containsKey("LazyPDFOcr") == true }.count
    }

    /// A layer stream written by hand, first in the page's contents: the key a reader looks for, an uncompressed body.
    static func addLayer(_ document: PdfDocument, _ content: String, _ pageIndex: Int = 0) throws {
        let marker = PdfDictionary()
        marker["Lang"] = PdfString(bytes: Array("en".utf8), isHex: false)
        let dictionary = PdfDictionary()
        dictionary["LazyPDFOcr"] = marker
        let stream = try document.add(PdfStream(dictionary, data: Latin1.bytes(content)))
        let page = document.pages[pageIndex]
        var items: [PdfObject]
        switch document.resolve(page.dictionary["Contents"]) {
        case let array as PdfArray: items = array.items
        case is PdfStream: items = page.dictionary["Contents"].map { [$0] } ?? []
        default: items = []
        }
        items.insert(stream, at: 0)
        page.dictionary["Contents"] = PdfArray(items)
    }

    static func latin(_ bytes: [UInt8]) -> String { Latin1.string(bytes) }

    static func texts(_ words: [OcrLayerWord]) -> [String] { words.map { $0.text } }
}
