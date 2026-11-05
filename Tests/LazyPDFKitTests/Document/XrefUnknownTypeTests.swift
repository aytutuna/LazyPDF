import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/XrefUnknownTypeTests.cs: the same cases. The one-page file is
// PageTestFiles.Make(1) of the C#, spelled out below.

final class XrefUnknownTypeTests: XCTestCase {
    /// Catalog 1, tree 2, font 3, page 4 and its contents 5.
    private func pageFile() -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R >>")
        pdf.obj(2, "<</Type /Pages /Kids [4 0 R] /Count 1 /MediaBox [0 0 200 300] >>")
        pdf.obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 3 0 R>>>> >>")
        pdf.stream(5, "", "BT /F1 12 Tf 20 100 Td (Page 1) Tj ET")
        return pdf.finish("/Root 1 0 R ")
    }

    /// An update whose cross-reference stream lists object 5 with the given type bytes.
    private func updated(_ entry: [UInt8]) throws -> [UInt8] {
        let file = pageFile()
        let startxref = try XCTUnwrap(file.lastIndexOf(TestPdf.latin("startxref")))
        let digits = file[(startxref + 9)...].drop { PdfLexer.isWhiteSpace(Int($0)) }.prefix { $0 >= 0x30 && $0 <= 0x39 }
        let previous = TestPdf.text(Array(digits))
        let at = file.count
        let data = entry + [1, UInt8(truncatingIfNeeded: at >> 8), UInt8(truncatingIfNeeded: at), 0]
        let update = "20 0 obj\n<</Type /XRef /Size 21 /W [1 2 1] /Index [5 1 20 1] /Root 1 0 R /Prev \(previous) /Length \(data.count)>>\nstream\n"
        return file + TestPdf.latin(update) + data + TestPdf.latin("\nendstream\nendobj\nstartxref\n\(at)\n%%EOF\n")
    }

    func test_entryOfAnUnknownTypeReadsAsNullAndHidesTheOlderOne() throws {
        let document = try PdfDocument.open(updated([3, 0, 0, 0]))
        XCTAssertNil(document.get(5))
    }

    func test_inUseEntryAtOffsetZeroReadsAsNull() throws {
        let document = try PdfDocument.open(updated([1, 0, 0, 0]))
        XCTAssertNil(document.get(5))
    }
}
