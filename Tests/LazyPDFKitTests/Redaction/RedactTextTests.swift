import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactTextTests.cs: the same cases.

final class RedactTextTests: XCTestCase {
    private func redact(_ content: String, _ word: String = RedactionKit.marker, _ resources: String = "") throws -> (result: RedactionResult, before: [DrawnGlyph], after: [DrawnGlyph]) {
        let document = try RedactionKit.page(content, resources)
        let before = RedactionKit.glyphs(document)
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, word))
        let output = try RedactionKit.open(result)
        return (result, before, RedactionKit.glyphs(output))
    }

    // The glyphs that stay are where they were: compare by position, in order, without the removed run.
    private func assertStay(_ before: [DrawnGlyph], _ after: [DrawnGlyph], _ removed: String) {
        var expected = before
        let length = removed.utf16.count
        while true {
            let units = Array(RedactionKit.text(expected).utf16)
            let needle = Array(removed.utf16)
            guard let at = units.indices.first(where: { $0 + length <= units.count && units[$0..<$0 + length].elementsEqual(needle) }) else { break }
            expected.removeSubrange(at..<at + length)
        }
        XCTAssertEqual(expected.count, after.count)
        for i in 0..<min(expected.count, after.count) {
            XCTAssertEqual(expected[i].text, after[i].text)
            XCTAssertEqual(expected[i].x, after[i].x, accuracy: 0.01)
            XCTAssertEqual(expected[i].y, after[i].y, accuracy: 0.01)
        }
    }

    func test_showStringLosesTheMarkedGlyphsAndTheRestStaysPut() throws {
        let (result, before, after) = try redact("BT /F1 12 Tf 50 700 Td (Hello ZQXMARKER world) Tj ET")
        assertStay(before, after, RedactionKit.marker)
        XCTAssertEqual(RedactionKit.text(after), "Hello  world")
        XCTAssertFalse(RedactionKit.holds(result.bytes, RedactionKit.marker))
        XCTAssertEqual(result.report.glyphs, 9)
    }

    func test_kerningArrayKeepsItsAdjustmentsAround() throws {
        let (_, before, after) = try redact("BT /F1 12 Tf 50 700 Td [(Hello ) -250 (ZQX) 120 (MARKER) -80 ( world)] TJ ET")
        assertStay(before, after, RedactionKit.marker)
    }

    func test_nextLineOperatorsStayInStep() throws {
        let (_, before, after) = try redact("BT /F1 12 Tf 14 TL 50 700 Td (one) Tj (two ZQXMARKER) ' 3 1 (three ZQXMARKER x) \" (four) ' ET")
        XCTAssertEqual(RedactionKit.text(after), "one" + "two " + "three  x" + "four")
        assertStay(before, after, RedactionKit.marker)
        XCTAssertEqual(try XCTUnwrap(before.first { $0.text == "f" }).y, try XCTUnwrap(after.first { $0.text == "f" }).y, accuracy: 0.01)
    }

    func test_characterAndWordSpacingAndScaleAreAccountedFor() throws {
        let (_, before, after) = try redact("BT /F1 12 Tf 50 700 Td 0.5 Tc 4 Tw 80 Tz (a ZQXMARKER b) Tj (c) Tj ET")
        assertStay(before, after, RedactionKit.marker)
        // The string after the removal continues from where the removed text ended.
        let was = before.filter { $0.text == "c" }, now = after.filter { $0.text == "c" }
        XCTAssertEqual(was.count, 1)
        XCTAssertEqual(now.count, 1)
        XCTAssertEqual(was[0].x, now[0].x, accuracy: 0.01)
    }

    func test_invisibleTextOfAnOcrLayerGoesToo() throws {
        let (result, _, after) = try redact("BT /F1 12 Tf 3 Tr 50 700 Td (ocr ZQXMARKER layer) Tj ET")
        XCTAssertEqual(RedactionKit.text(after), "ocr  layer")
        XCTAssertFalse(RedactionKit.holds(result.bytes, RedactionKit.marker))
    }

    func test_clippedTextOutsideTheMarkStays() throws {
        let (_, _, after) = try redact("q 0 0 10 10 re W n BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET Q BT /F1 12 Tf 50 100 Td (visible) Tj ET", "visible")
        XCTAssertEqual(RedactionKit.text(after), "ZQXMARKER")
    }

    func test_clippedTextUnderAMarkIsRemoved() throws {
        let document = try RedactionKit.page("q 0 0 40 800 re W n BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET Q")
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(40, 690, 200, 720))])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "")
        XCTAssertFalse(RedactionKit.holds(result.bytes, RedactionKit.marker))
    }

    func test_showStringsOfSeveralPlacesAreEachCut() throws {
        let (_, before, after) = try redact("BT /F1 12 Tf 50 700 Td (ZQXMARKER top) Tj ET BT /F1 12 Tf 50 650 Td (mid ZQXMARKER) Tj ET")
        XCTAssertEqual(before.count - 18, after.count)
        XCTAssertEqual(RedactionKit.text(after), " topmid ")
    }

    func test_markOnEmptyAreaRemovesNothing() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 50 700 Td (kept) Tj ET")
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(300, 300, 400, 400))])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "kept")
        XCTAssertEqual(result.report.glyphs, 0)
        XCTAssertTrue(result.report.description.contains("Nothing"))
    }

    func test_rectangleOverPartOfAGlyphTakesIt() throws {
        let document = try RedactionKit.page("BT /F1 20 Tf 50 700 Td (ABCDE) Tj ET")
        let glyphs = RedactionKit.glyphs(document)
        // A box over the middle of C only.
        let x = glyphs[2].x + 3
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(x, 695, x + 2, 715))])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "ABDE")
    }

    func test_theDocumentItselfIsNotChanged() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 50 700 Td (Hello ZQXMARKER) Tj ET")
        let original = try document.saveRewrite()
        _ = try PdfRedactor(document).apply([try RedactionKit.markOf(document, 0, RedactionKit.marker)])
        XCTAssertEqual(RedactionKit.text(document), "Hello ZQXMARKER")
        XCTAssertEqual(original.count, try document.saveRewrite().count)
    }
}
