import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactShiftTests.cs: the same cases.

final class RedactShiftTests: XCTestCase {
    private func shifts(_ document: PdfDocument) -> Int {
        ContentParser.parse(document.pages[0].contents()).filter { $0.operator == "TJ" }
            .reduce(0) { $0 + (($1.operands.last as? PdfArray)?.items.filter { $0 is PdfNumber }.count ?? 0) }
    }

    private func redact(_ content: String, _ word: String) throws -> (output: PdfDocument, before: [DrawnGlyph], after: [DrawnGlyph]) {
        let document = try RedactionKit.page(content)
        let before = RedactionKit.glyphs(document)
        let result = try PdfRedactor(document).apply([try RedactionKit.markOf(document, 0, word)])
        let output = try RedactionKit.open(result)
        return (output, before, RedactionKit.glyphs(output))
    }

    private func assertStayedPut(_ before: [DrawnGlyph], _ after: [DrawnGlyph], _ first: Int, _ length: Int) {
        let kept = before.enumerated().filter { $0.offset < first || $0.offset >= first + length }.map { $0.element }
        XCTAssertEqual(kept.count, after.count)
        for i in 0..<min(kept.count, after.count) {
            XCTAssertEqual(kept[i].text, after[i].text)
            XCTAssertEqual(kept[i].x, after[i].x, accuracy: 0.01)
        }
    }

    func test_removedRunLeavesOneShiftNotOnePerCharacter() throws {
        let (output, before, after) = try redact("BT /F1 12 Tf 50 700 Td (Name: John Smith and more) Tj ET", "John Smith")
        XCTAssertEqual(shifts(output), 1)
        assertStayedPut(before, after, 6, 10)
    }

    func test_shiftsAroundOriginalKerningBecomeOne() throws {
        let (output, before, after) = try redact("BT /F1 12 Tf 50 700 Td [(Name: Jo) -30 (hn) 120 ( Smith) -40 ( and more)] TJ ET", "John Smith")
        XCTAssertEqual(shifts(output), 1)
        assertStayedPut(before, after, 6, 10)
    }

    func test_noShiftIsKeptWhenTheLineEndsWithTheRemovedRun() throws {
        let (output, before, after) = try redact("BT /F1 12 Tf 50 700 Td (Name: John Smith) Tj 0 -20 Td (next) Tj ET", "John Smith")
        XCTAssertEqual(shifts(output), 0)
        assertStayedPut(before, after, 6, 10)
    }

    func test_shiftIsKeptWhenAnotherShowContinuesTheLine() throws {
        let (output, before, after) = try redact("BT /F1 12 Tf 50 700 Td (Name: John Smith) Tj ( tail) Tj ET", "John Smith")
        XCTAssertEqual(shifts(output), 1)
        assertStayedPut(before, after, 6, 10)
    }

    func test_paintStateBetweenPathAndPaintDoesNotKeepTheSegments() throws {
        let document = try RedactionKit.page("230 210 m 270 210 l 257.5 233.5 l 1 0 0 rg f")
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(200, 200, 300, 300))])
        let output = try RedactionKit.open(result)
        let content = try RedactionKit.latin(output)
        XCTAssertFalse(content.contains("257.5 233.5"))
        XCTAssertFalse(content.contains("270 210"))
        XCTAssertTrue(content.contains("1 0 0 rg"))
        XCTAssertEqual(result.report.paths, 1)
    }

    private func shows(_ document: PdfDocument) -> Int {
        ContentParser.parse(document.pages[0].contents()).filter { $0.operator == "Tj" || $0.operator == "TJ" }.count
    }

    func test_runSpreadOverSeveralShowsLeavesNoWidthPerShow() throws {
        let (output, _, _) = try redact("BT /F1 12 Tf 50 700 Td (J) Tj (o) Tj (h) Tj (n) Tj ( ) Tj (S) Tj (m) Tj (i) Tj (t) Tj (h) Tj ET", "John Smith")
        XCTAssertEqual(shifts(output), 0)
        XCTAssertEqual(shows(output), 0)
    }

    func test_runSpreadOverSeveralShowsMovesTheTotalToTheNextShow() throws {
        let (output, before, after) = try redact("BT /F1 12 Tf 50 700 Td (Name: J) Tj (o) Tj (h) Tj (n) Tj ( after) Tj ET", "John")
        XCTAssertEqual(shifts(output), 1)
        assertStayedPut(before, after, 6, 4)
    }

    func test_positionsBetweenRemovedShowsDoNotKeepTheirAdvance() throws {
        let (output, before, after) = try redact("BT /F1 12 Tf 50 700 Td (J) Tj 6 0 Td (o) Tj 6.672 0 Td (h) Tj 6.672 0 Td (n) Tj 6.672 0 Td ( tail) Tj ET", "John")
        let content = try RedactionKit.latin(output)
        XCTAssertFalse(content.contains("6 0 Td"))
        XCTAssertFalse(content.contains("6.672 0 Td"))
        assertStayedPut(before, after, 0, 4)
    }

    func test_matricesBetweenRemovedShowsDoNotKeepTheirPlace() throws {
        let (output, before, after) = try redact("BT /F1 12 Tf 1 0 0 1 56 700 Tm (J) Tj 1 0 0 1 62 700 Tm (o) Tj 1 0 0 1 68.672 700 Tm (h) Tj 1 0 0 1 75.344 700 Tm (n) Tj 1 0 0 1 100 700 Tm (tail) Tj ET", "John")
        let content = try RedactionKit.latin(output)
        XCTAssertFalse(content.contains("62 700"))
        XCTAssertFalse(content.contains("68.672"))
        XCTAssertFalse(content.contains("75.344"))
        assertStayedPut(before, after, 0, 4)
    }
}
