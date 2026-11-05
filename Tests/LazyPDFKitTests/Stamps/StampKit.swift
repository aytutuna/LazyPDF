import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Stamps/StampKit.cs. PigText has no twin (PdfPig). The C# ArialSource reads arial.ttf
// from the Windows fonts folder; here it hands out the synthetic font of the font program tests, which has A, B, space,
// ğ, ı, İ and À, so the tests that need Turkish letters use those.

/// A glyph a stamp drew, placed on the page as shown: the origin in display points (y down) and the direction the text runs in.
struct StampGlyph {
    let text: String
    let x: Double
    let y: Double
    let dirX: Double
    let dirY: Double
    let size: Double
    let alpha: Double
}

final class ArialSource: FontSource {
    private let data: [UInt8]

    init() throws {
        data = try SyntheticFonts.ttf()
    }

    func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(data) }
}

enum StampKit {
    /// An 8 by 6 pixel colour JPEG.
    static let sampleJpeg =
        "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAGAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDI+Fv7K+jfueYe38J/wooor57Nc6zH6y/3zO/gHiHNf7Ep/wC0SP/Z"

    static var jpeg: [UInt8] { [UInt8](Data(base64Encoded: sampleJpeg) ?? Data()) }

    /// A document of `count` pages 200 by 300 points, each with a little text of its own.
    static func doc(_ count: Int = 3) throws -> PdfDocument {
        try pages((1...count).map { (keys: "", content: "BT /F1 12 Tf 50 50 Td (\($0)) Tj ET") })
    }

    /// One page per entry: the page's extra keys and its content. All have Helvetica as /F1 unless their keys give /Resources.
    static func pages(_ pages: [(keys: String, content: String)]) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = pages.indices.map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(pages.count) /MediaBox [0 0 200 300]>>")
        let font = 3 + 2 * pages.count
        for (i, page) in pages.enumerated() {
            let resources = page.keys.contains("/Resources") ? "" : "/Resources <</Font <</F1 \(font) 0 R>>>>"
            pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(3 + pages.count + i) 0 R \(resources) \(page.keys)>>")
        }
        for (i, page) in pages.enumerated() { pdf.stream(3 + pages.count + i, "", page.content) }
        pdf.obj(font, ContentTestPdf.helvetica)
        return try PdfDocument.open(pdf.finish())
    }

    /// Assert.Single.
    static func single<T>(_ items: [T], file: StaticString = #filePath, line: UInt = #line) throws -> T {
        XCTAssertEqual(items.count, 1, file: file, line: line)
        return try XCTUnwrap(items.first, file: file, line: line)
    }

    static func rewrite(_ document: PdfDocument) throws -> [UInt8] { try document.saveRewrite() }

    static func glyphs(_ document: PdfDocument, _ pageIndex: Int) -> [StampGlyph] {
        let page = document.pages[pageIndex]
        let collector = Collector(PageGeometry(page))
        ContentInterpreter(document).run(page, collector)
        return collector.found
    }

    static func text(_ glyphs: [StampGlyph]) -> String { glyphs.map { $0.text }.joined() }

    private final class Collector: ContentVisitor {
        let geometry: PageGeometry
        var found: [StampGlyph] = []

        init(_ geometry: PageGeometry) {
            self.geometry = geometry
            super.init()
        }

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            if !context.marked.contains(where: { $0.tag == "Artifact" }) { return }
            let m = glyph.matrix
            let p = geometry.toDisplay(m.e, m.f)
            let q = geometry.toDisplay(m.e + m.a, m.f + m.b)
            let length = (pow(q.x - p.x, 2) + pow(q.y - p.y, 2)).squareRoot()
            found.append(StampGlyph(text: glyph.unicode ?? "", x: p.x, y: p.y, dirX: (q.x - p.x) / length, dirY: (q.y - p.y) / length,
                                    size: length, alpha: context.state.fillAlpha))
        }
    }

    static func contentStreams(_ document: PdfDocument, _ pageIndex: Int) throws -> [PdfDictionary] {
        let page = document.pages[pageIndex]
        let contents = document.resolve(page.dictionary["Contents"])
        let items = (contents as? PdfArray)?.items ?? page.dictionary["Contents"].map { [$0] } ?? []
        return try items.map { try XCTUnwrap((document.resolve($0) as? PdfStream)?.dictionary) }
    }

    static func latin(_ document: PdfDocument, _ pageIndex: Int) -> String { Latin1.string(document.pages[pageIndex].contents()) }
}
