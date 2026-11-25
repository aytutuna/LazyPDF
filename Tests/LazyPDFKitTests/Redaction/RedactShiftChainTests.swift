import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactShiftChainTests.cs: the same cases. What stays of the positions between
// removed shows: a matrix or text matrix per show, or a size per show, gives the width of each removed letter.

final class RedactShiftChainTests: XCTestCase {
    private let letters = PdfRect(95, 90, 140, 120)

    private func count(_ content: String, _ op: String) -> Int {
        ContentParser.parse(Latin1.bytes(content)).filter { $0.operator == op }.count
    }

    func test_chainOfMatricesBetweenRemovedShowsBecomesOne() throws {
        func line(_ letter: String, _ move: String) -> String { "\(move) cm BT /F1 12 Tf 100 100 Td (\(letter)) Tj ET " }
        let document = try RedactionKit.page(line("Z", "1 0 0 1 6 0") + line("Q", "1 0 0 1 6.67 0") + line("X", "1 0 0 1 6.67 0") + "BT /F1 12 Tf 100 300 Td (kept) Tj ET")
        let before = try XCTUnwrap(RedactionKit.glyphs(document).first { abs($0.y - 300) < 0.01 }).x
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, letters)])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(count(try RedactionKit.latin(output), "cm"), 1)
        XCTAssertEqual(try XCTUnwrap(RedactionKit.glyphs(output).first { abs($0.y - 300) < 0.01 }).x, before, accuracy: 0.01)
    }

    func test_textMatrixPerRemovedShowInsideASavedStateIsDropped() throws {
        func line(_ letter: String, _ x: String) -> String { "q BT /F1 12 Tf 1 0 0 1 \(x) 100 Tm (\(letter)) Tj ET Q " }
        let document = try RedactionKit.page(line("Z", "106") + line("Q", "112.67") + line("X", "119.34") + "BT /F1 12 Tf 1 0 0 1 300 400 Tm (kept) Tj ET")
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, letters)])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(count(try RedactionKit.latin(output), "Tm"), 1)
        XCTAssertEqual(try XCTUnwrap(RedactionKit.glyphs(output).first).x, 300, accuracy: 0.01)
    }

    func test_shiftOfARemovedShowMovesToTheNextOneWhateverItsSize() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 100 Td (Z) Tj /F1 12.01 Tf (Q) Tj /F1 12 Tf (X) Tj /F1 12.01 Tf (C) Tj /F1 12 Tf (kept) Tj ET")
        let before = try XCTUnwrap(RedactionKit.glyphs(document).last).x
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXC"))
        let output = try RedactionKit.open(result)
        XCTAssertEqual(count(try RedactionKit.latin(output), "TJ"), 1)
        XCTAssertEqual(try XCTUnwrap(RedactionKit.glyphs(output).last).x, before, accuracy: 0.05)
    }
}
