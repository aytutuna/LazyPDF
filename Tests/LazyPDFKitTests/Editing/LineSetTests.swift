import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/LineSetTests.cs: the same cases. Justify and line spacing on lines whose
// strings are placed one by one, drawn twice, or drawn out of reading order.

final class LineSetTests: XCTestCase {
    private func block(_ editor: PageEditor) throws -> TextObject {
        try XCTUnwrap(try editor.objects.compactMap { $0 as? TextObject }.first)
    }

    func test_justifyMovesAStringThatTdPlacesBehindTheSpacesBeforeIt() throws {
        let session = try EditKit.session("BT /F1 12 Tf 14 TL 50 700 Td (Hello ) Tj 31 0 Td (World) Tj -31 -14 Td (a much longer second line here) Tj ET")
        let editor = try PageEditor(session, 0)
        let before = try EditKit.glyphs(session)
        let result = try editor.setAlignment(try block(editor), .justify)
        XCTAssertTrue(result.done, result.problem ?? "")
        let lines = TextPage.create(session.document, session.document.pages[0]).lines.sorted { $0.bounds.top > $1.bounds.top }
        let upper = try XCTUnwrap(lines.filter { $0.bounds.top > 690 }.map { $0.bounds.right }.max())
        XCTAssertEqual(try XCTUnwrap(lines.last).bounds.right, upper, accuracy: 0.05)
        let after = try EditKit.glyphs(session)
        XCTAssertTrue(after[6].x > before[6].x + 20)
    }

    func test_lineSpacingMovesBothStrikesOfADoubleStruckLine() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (first line) Tj ET BT /F1 12 Tf 50 686 Td (second) Tj ET BT /F1 12 Tf 50.2 686 Td (second) Tj ET")
        let editor = try PageEditor(session, 0)
        XCTAssertTrue(try editor.setLineSpacing(try block(editor), 30).done)
        let second = try EditKit.glyphs(session).filter { $0.text == "s" && $0.y < 690 }
        XCTAssertEqual(second.count, 2)
        for g in second { XCTAssertEqual(g.y, 670, accuracy: 0.05) }
    }

    func test_justifyOfLinesDrawnOutOfOrderLeavesTheWordSpacingOfTheRestAlone() throws {
        let content = "BT /F1 12 Tf 50 686 Td (line two is a longer one) Tj ET BT /F1 12 Tf 50 700 Td (line one) Tj ET BT /F1 12 Tf 50 100 Td (tail text) Tj ET"
        let session = try EditKit.session(content)
        let editor = try PageEditor(session, 0)
        let result = try editor.setAlignment(try block(editor), .justify)
        XCTAssertTrue(result.done, result.problem ?? "")
        let shown = try EditKit.shown(session)
        XCTAssertTrue(try XCTUnwrap(EditKit.of(shown, "line one").first { $0.text == " " }).tw > 0)
        for g in EditKit.of(shown, "line two is") { XCTAssertEqual(g.tw, 0) }
        for g in EditKit.of(shown, "tail text") { XCTAssertEqual(g.tw, 0) }
    }

    func test_lineSpacingOfLinesDrawnOutOfOrderLeavesTheRiseOfTheRestAlone() throws {
        let content = "BT /F1 12 Tf 50 672 Td (line three) Tj ET BT /F1 12 Tf 50 700 Td (line one) Tj ET BT /F1 12 Tf 50 686 Td (line two) Tj ET BT /F1 12 Tf 50 100 Td (tail) Tj ET"
        let session = try EditKit.session(content)
        let editor = try PageEditor(session, 0)
        XCTAssertTrue(try editor.setLineSpacing(try block(editor), 20).done)
        let shown = try EditKit.shown(session)
        XCTAssertEqual(EditKit.of(shown, "line three")[0].y, 660, accuracy: 0.05)
        XCTAssertEqual(EditKit.of(shown, "line two")[0].y, 680, accuracy: 0.05)
        XCTAssertEqual(EditKit.of(shown, "tail")[0].y, 100, accuracy: 0.05)
    }
}
