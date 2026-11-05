import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/RepairLimitsTests.cs: the same cases.

final class RepairLimitsTests: XCTestCase {
    func test_trailersInsideAValueThatIsNotADictionaryAreScannedOnce() {
        let depth = 40_000
        let text = "%PDF-1.4\n" + String(repeating: "trailer (", count: depth) + String(repeating: ")", count: depth)
        let file = TestPdf.latin(text)

        let started = Date()
        assertReadFails(try PdfDocument.open(file))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func test_repairWithNoObjectNumbersLeftIsAReadErrorNotAnInvalidOperation() {
        let file = TestPdf.latin("%PDF-1.4\n8388607 0 obj\n<</Type/Page>>\nendobj\n")
        assertReadFails(try PdfDocument.open(file))
    }

    func test_aSharedXrefStreamIsReadOncePerFile() throws {
        let entries = 200_000, sections = 2000
        let pdf = TestPdf.withPages(1)
        let stream = pdf.position
        let rows = [UInt8](repeating: 0, count: entries * 5)
        pdf.stream(9, "/Type /XRef /Size \(entries + 10) /Index [10 \(entries)] /W [1 3 1] /Filter /FlateDecode", TestPdf.deflate(rows))
        let first = pdf.finish("/Root 1 0 R")
        var text = ""
        var previous = try XCTUnwrap(first.lastIndexOf(TestPdf.latin("xref\n0")))
        let end = first.count
        for _ in 0..<sections {
            let at = end + text.utf8.count
            text += "xref\n0 1\n0000000000 65535 f \ntrailer\n<</Size \(entries + 10) /Root 1 0 R /Prev \(previous) /XRefStm \(stream)>>\n"
            text += "startxref\n\(at)\n%%EOF\n"
            previous = at
        }
        let file = first + TestPdf.latin(text)

        let started = Date()
        let document = try PdfDocument.open(file)
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
