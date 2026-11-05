import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/StructureFixtures.cs. Reopen does not hand the files to PdfPig, which has
// no Swift twin; the document is still written both ways and read again.

enum StructureFixtures {
    static func open(_ pages: Int = 3) throws -> PdfDocument {
        try PdfDocument.open(TestPdf.simple(pages))
    }

    /// A file with `pages` pages (objects 3 and up, 200 by 300 points) and a catalog that carries `catalog`; `more` adds
    /// objects from number 20.
    static func file(_ catalog: String, _ more: ((TestPdf) -> Void)? = nil, pages: Int = 3, pageEntries: String = "") throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalog)>>")
        let kids = (0..<pages).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(pages) /MediaBox [0 0 200 300]>>")
        for i in 0..<pages { pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R \(pageEntries)>>") }
        more?(pdf)
        return try PdfDocument.open(pdf.finish())
    }

    /// The document written both ways and read again; the document read from the update is returned (the rewrite is read
    /// too, so both are exercised).
    static func reopen(_ document: PdfDocument, file: StaticString = #filePath, line: UInt = #line) throws -> PdfDocument {
        let rewritten = try document.saveRewrite()
        XCTAssertEqual(try PdfDocument.open(rewritten).pages.count, document.pages.count, file: file, line: line)
        XCTAssertTrue(try PdfDocument.open(rewritten).repairs.isEmpty, file: file, line: line)

        let updated = try document.saveIncremental()
        let reopened = try PdfDocument.open(updated)
        XCTAssertEqual(reopened.pages.count, document.pages.count, file: file, line: line)
        XCTAssertTrue(reopened.repairs.isEmpty, "\(reopened.repairs)", file: file, line: line)
        return reopened
    }

    /// The document rewritten and read again.
    static func rewritten(_ document: PdfDocument) throws -> PdfDocument {
        try PdfDocument.open(document.saveRewrite())
    }

    static func toPage(_ index: Int) -> PdfDestination {
        PdfDestination(index, .xyz, left: 10, top: 250)
    }
}
