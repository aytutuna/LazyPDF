import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactTextRunTests.cs: the same cases. A producer that writes a state or
// position operator for every run still gets one shift for what was removed, and no position of a removed run.

final class RedactTextRunTests: XCTestCase {
    private func redact(_ content: String, _ mark: PdfRect) throws -> (content: String, before: [DrawnGlyph], after: [DrawnGlyph]) {
        let document = try RedactionKit.page(content)
        let before = RedactionKit.glyphs(document)
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, mark)])
        let output = try RedactionKit.open(result)
        return (try RedactionKit.latin(output), before, RedactionKit.glyphs(output))
    }

    private func assertStayedPut(_ before: [DrawnGlyph], _ after: [DrawnGlyph], _ removed: [Int]) {
        let kept = before.enumerated().filter { !removed.contains($0.offset) }.map { $0.element }
        XCTAssertEqual(kept.count, after.count)
        for i in 0..<min(kept.count, after.count) {
            XCTAssertEqual(kept[i].text, after[i].text)
            XCTAssertEqual(kept[i].x, after[i].x, accuracy: 0.01)
        }
    }

    func test_repeatedFontOperatorBetweenShowsDoesNotKeepEachWidth() throws {
        let (content, before, after) = try redact("BT /F1 12 Tf 100 700 Td (J) Tj /F1 12 Tf (o) Tj /F1 12 Tf (h) Tj /F1 12 Tf (n) Tj /F1 12 Tf ( Smith) Tj ET", PdfRect(95, 690, 124, 715))
        XCTAssertFalse(content.contains("556"))
        XCTAssertFalse(content.contains("-500"))
        XCTAssertTrue(content.contains("-2168"))
        assertStayedPut(before, after, [0, 1, 2, 3])
    }

    func test_relativeMovesWithLeadingBetweenShowsAreSummed() throws {
        let (content, before, after) = try redact("BT /F1 12 Tf 100 700 Td (J) Tj 10 0 TD (o) Tj 10 0 TD (h) Tj 10 0 TD (n) Tj ET", PdfRect(108, 690, 125, 715))
        XCTAssertFalse(content.contains("10 0 TD"))
        XCTAssertTrue(content.contains("30 0 TD"))
        assertStayedPut(before, after, [1, 2])
    }

    func test_positionOfARemovedRunSetInAMatrixPerShowDoesNotStay() throws {
        let content = [("J", 100), ("o", 120), ("h", 140), ("n", 160)].map { "q 1 0 0 1 \($0.1) 700 cm BT /F1 12 Tf (\($0.0)) Tj ET Q " }.joined()
        let (written, before, after) = try redact(content, PdfRect(115, 690, 150, 715))
        XCTAssertFalse(written.contains("120 700 cm"))
        XCTAssertFalse(written.contains("140 700 cm"))
        XCTAssertTrue(written.contains("100 700 cm"))
        XCTAssertTrue(written.contains("160 700 cm"))
        assertStayedPut(before, after, [1, 2])
    }
}
