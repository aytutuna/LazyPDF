import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageTestFiles.cs: small files for the page tests, page `i` shows "Page i+1" and
// every page has the same font. The C# reads the saved file with PdfPig too; `reopen` has no twin of that, and gives the text
// the Text layer reads from the reopened pages instead.

enum PageTestFiles {
    static let font = 3

    static func pageObject(_ index: Int) -> Int { 4 + index }

    /// The first object number the extras may use.
    static func free(_ count: Int) -> Int { 4 + 2 * count }

    /// Catalog 1, tree 2 (flat, with `rootExtra`), font 3, pages 4... and their contents after them. `pageExtra` adds entries
    /// to a page dictionary, `add` adds objects from `free` on.
    static func make(_ count: Int, _ catalogExtra: String = "", pageExtra: ((Int) -> String)? = nil, rootExtra: String = "",
                     add: ((TestPdf) -> Void)? = nil, trailerExtra: String = "") -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalogExtra)>>")
        let kids = (0..<count).map { "\(pageObject($0)) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(count) /MediaBox [0 0 200 300] \(rootExtra)>>")
        pdf.obj(font, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        for i in 0..<count {
            pdf.obj(pageObject(i), "<</Type /Page /Parent 2 0 R /Contents \(4 + count + i) 0 R /Resources <</Font <</F1 \(font) 0 R>>>> \(pageExtra?(i) ?? "")>>")
        }
        for i in 0..<count { pdf.stream(4 + count + i, "", "BT /F1 12 Tf 20 100 Td (Page \(i + 1)) Tj ET") }
        add?(pdf)
        return pdf.finish("/Root 1 0 R " + trailerExtra)
    }

    static func open(_ count: Int, _ catalogExtra: String = "", pageExtra: ((Int) -> String)? = nil, rootExtra: String = "",
                     add: ((TestPdf) -> Void)? = nil) throws -> PdfDocument {
        try PdfDocument.open(make(count, catalogExtra, pageExtra: pageExtra, rootExtra: rootExtra, add: add))
    }

    /// The "Page n" numbers the pages show, in order.
    static func order(_ document: PdfDocument) -> [Int] {
        document.pages.map { page in
            let text = Latin1.string(page.contents())
            guard let found = text.range(of: #"\(Page \d+\)"#, options: .regularExpression) else { return -1 }
            return Int(text[found].filter { $0.isNumber }) ?? -1
        }
    }

    /// Saves by rewrite and reads the result with our reader (no repairs); returns the text of each page.
    @discardableResult
    static func reopen(_ document: PdfDocument, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let again = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(again.repairs, [], file: file, line: line)
        let cache = TextCache(again)
        return (0..<again.pages.count).map { TextExport.page(cache.get($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The bytes of a string object, read as Latin-1.
    static func text(_ value: PdfObject?) -> String {
        Latin1.string((value as? PdfString)?.bytes ?? [])
    }

    /// Commits through a session, reopens the committed bytes and returns that document.
    static func commit(_ session: PdfEditSession, _ label: String = "edit", file: StaticString = #filePath, line: UInt = #line) throws -> PdfDocument {
        XCTAssertTrue(try session.commit(label), file: file, line: line)
        let document = try PdfDocument.open(session.current)
        XCTAssertEqual(document.repairs, [], file: file, line: line)
        return document
    }
}
