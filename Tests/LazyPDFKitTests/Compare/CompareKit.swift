import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/CompareKit.cs. The C# test classes import its methods with `using static`;
// here they inherit them from `CompareTestCase`, which forwards to `CompareKit`. The C# CompareArial reads arial.ttf from
// the Windows fonts folder; here it hands out the synthetic font of the font program tests, which has A, B, space, ğ, ı, İ
// and À, so the tests that need Turkish letters use those.

// Foundation has a ComparisonResult of its own, so the name alone is ambiguous where both are imported.
typealias ComparisonResult = LazyPDFKit.ComparisonResult

/// A line of text on a made page: /F1 Helvetica, /F2 Times-Roman, /F3 Helvetica-Bold.
struct CompareLine {
    let text: String
    let font: String
    let size: Double
    let color: String

    init(_ text: String, font: String = "F1", size: Double = 12, color: String = "0 0 0") {
        self.text = text
        self.font = font
        self.size = size
        self.color = color
    }
}

final class CompareArial: FontSource {
    private let data: [UInt8]

    init() throws {
        data = try SyntheticFonts.ttf()
    }

    func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(data) }
}

enum CompareKit {
    /// An 8 by 6 pixel colour JPEG.
    static let sampleJpeg =
        "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAGAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDI+Fv7K+jfueYe38J/wooor57Nc6zH6y/3zO/gHiHNf7Ep/wC0SP/Z"

    static func l(_ text: String) -> CompareLine { CompareLine(text) }

    /// A document with one page for each argument; every page is 612 by 792 with its lines from the top, 20 points apart.
    static func doc(_ pages: [[CompareLine]]) throws -> PdfDocument { try open(bytes(pages)) }

    static func doc(_ pages: [[String]]) throws -> PdfDocument { try doc(pages.map { $0.map(l) }) }

    static func open(_ bytes: [UInt8]) throws -> PdfDocument { try PdfDocument.open(bytes) }

    /// The file. Page `i` is object `3 + i` with its content after the pages; the three fonts follow. `pageKeys` adds keys to
    /// every page, `more` adds objects numbered from the number it is given.
    static func bytes(_ pages: [[CompareLine]], pageKeys: String = "", pageExtra: ((Int) -> [String])? = nil,
                      more: ((TestPdf, Int) -> Void)? = nil, trailer: String = "") -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = pages.indices.map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(pages.count) /MediaBox [0 0 612 792]>>")
        let font = 3 + 2 * pages.count
        for i in 0..<pages.count {
            let extra = pageExtra.map { $0(i).joined(separator: " ") } ?? ""
            pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(3 + pages.count + i) 0 R /Resources <</Font <</F1 \(font) 0 R /F2 \(font + 1) 0 R /F3 \(font + 2) 0 R>>>> \(pageKeys) \(extra)>>")
        }
        for i in 0..<pages.count { pdf.stream(3 + pages.count + i, "", content(pages[i])) }
        pdf.obj(font, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.obj(font + 1, "<</Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding>>")
        pdf.obj(font + 2, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding>>")
        more?(pdf, font + 3)
        return pdf.finish("/Root 1 0 R \(trailer)")
    }

    static func content(_ lines: [CompareLine]) -> String {
        var sb = ""
        for (i, line) in lines.enumerated() {
            let text = line.text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
            sb += "BT /\(line.font) \(TextTestPdf.number(line.size)) Tf \(line.color) rg 72 \(740 - 20 * i) Td (\(text)) Tj ET\n"
        }
        return sb
    }

    static func compare(_ before: PdfDocument, _ after: PdfDocument, _ options: CompareOptions? = nil) throws -> ComparisonResult {
        try PdfComparer.compare(before, after, options)
    }

    static func compare(_ before: [[String]], _ after: [[String]], _ options: CompareOptions? = nil) throws -> ComparisonResult {
        let a = try doc(before)
        let b = try doc(after)
        return try PdfComparer.compare(a, b, options)
    }

    /// Lines of ten words each that carry the topic, so that pages with different topics have nothing in common.
    static func page(_ topic: String, _ lines: Int = 6) -> [String] {
        stride(from: 1, through: lines, by: 1).map { i in
            "\(topic) line\(i) " + (1...8).map { k in "\(topic)\(i)w\(k)" }.joined(separator: " ")
        }
    }

    /// Assert.Single.
    static func single<T>(_ items: [T], file: StaticString = #filePath, line: UInt = #line) throws -> T {
        XCTAssertEqual(items.count, 1, file: file, line: line)
        return try XCTUnwrap(items.first, file: file, line: line)
    }

    /// Assert.Single with a predicate.
    static func single<T>(_ items: [T], where match: (T) -> Bool, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try single(items.filter(match), file: file, line: line)
    }

    /// Assert.InRange.
    static func assertInRange(_ value: Double, _ low: Double, _ high: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value >= low && value <= high, "\(value) is not in [\(low), \(high)]", file: file, line: line)
    }

    /// The text the glyphs of page `pageIndex` stand for, in the order they are shown, with nothing between lines; the
    /// stand-in for the C# tests' PdfPig text of a page.
    static func shown(_ bytes: [UInt8], _ pageIndex: Int = 0) throws -> String {
        let document = try PdfDocument.open(bytes)
        let collector = Glyphs()
        ContentInterpreter(document).run(document.pages[pageIndex], collector)
        return collector.text
    }

    private final class Glyphs: ContentVisitor {
        var text = ""

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            text += glyph.unicode ?? ""
        }
    }

    /// The pages as a line: `+n` added, `-n` removed, `a>b` moved, `a=b` paired.
    static func shape(_ r: ComparisonResult) -> String {
        r.pages.map { p in
            p.isAdded ? "+\(p.newIndex)" : p.isRemoved ? "-\(p.oldIndex)" : p.moved ? "\(p.oldIndex)>\(p.newIndex)" : "\(p.oldIndex)=\(p.newIndex)"
        }.joined(separator: " ")
    }
}

class CompareTestCase: XCTestCase {
    func l(_ text: String) -> CompareLine { CompareKit.l(text) }

    func doc(_ pages: [[CompareLine]]) throws -> PdfDocument { try CompareKit.doc(pages) }

    func doc(_ pages: [[String]]) throws -> PdfDocument { try CompareKit.doc(pages) }

    func open(_ bytes: [UInt8]) throws -> PdfDocument { try CompareKit.open(bytes) }

    func bytes(_ pages: [[CompareLine]], pageKeys: String = "", pageExtra: ((Int) -> [String])? = nil,
               more: ((TestPdf, Int) -> Void)? = nil, trailer: String = "") -> [UInt8] {
        CompareKit.bytes(pages, pageKeys: pageKeys, pageExtra: pageExtra, more: more, trailer: trailer)
    }

    func compare(_ before: PdfDocument, _ after: PdfDocument, _ options: CompareOptions? = nil) throws -> ComparisonResult {
        try CompareKit.compare(before, after, options)
    }

    func compare(_ before: [[String]], _ after: [[String]], _ options: CompareOptions? = nil) throws -> ComparisonResult {
        try CompareKit.compare(before, after, options)
    }

    func page(_ topic: String, _ lines: Int = 6) -> [String] { CompareKit.page(topic, lines) }

    func single<T>(_ items: [T], file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try CompareKit.single(items, file: file, line: line)
    }

    func single<T>(_ items: [T], where match: (T) -> Bool, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try CompareKit.single(items, where: match, file: file, line: line)
    }

    func assertInRange(_ value: Double, _ low: Double, _ high: Double, file: StaticString = #filePath, line: UInt = #line) {
        CompareKit.assertInRange(value, low, high, file: file, line: line)
    }

    func shape(_ r: ComparisonResult) -> String { CompareKit.shape(r) }
}
