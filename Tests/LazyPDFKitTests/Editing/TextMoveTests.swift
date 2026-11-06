import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/TextMoveTests.cs: the same cases, except that the PdfPig assertion of
// TheLastBlockMovesAndTheTextObjectStillEnds has no twin. A text block is moved with a matrix round its operators,
// leaving its coordinates and the rest of the text object alone.

final class TextMoveTests: XCTestCase {
    private let two = "BT /F1 12 Tf 50 700 Td (Block one line a) Tj 0 -14 Td (line b of one) Tj 0 -150 Td (Block two) Tj ET"

    private func assertMoved(_ before: [EditGlyphAt], _ after: [EditGlyphAt], _ moved: (Int) -> Bool, _ dx: Double, _ dy: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(before.count, after.count, file: file, line: line)
        for i in 0..<min(before.count, after.count) {
            XCTAssertEqual(before[i].text, after[i].text, file: file, line: line)
            XCTAssertEqual(after[i].x, before[i].x + (moved(i) ? dx : 0), accuracy: 0.005, file: file, line: line)
            XCTAssertEqual(after[i].y, before[i].y + (moved(i) ? dy : 0), accuracy: 0.005, file: file, line: line)
        }
    }

    private func blocks(_ editor: PageEditor) throws -> [TextObject] {
        try editor.objects.compactMap { $0 as? TextObject }.sorted { $0.bounds.top > $1.bounds.top }
    }

    func test_oneBlockOfTwoInOneTextObjectMovesAlone() throws {
        let session = try EditKit.session(two)
        let editor = try PageEditor(session, 0)
        let before = try EditKit.glyphs(session)
        let found = try blocks(editor)
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(try editor.move([found[0]], 40, -20).done)
        assertMoved(before, try EditKit.glyphs(session), { $0 < 29 }, 40, -20)
    }

    func test_theLastBlockMovesAndTheTextObjectStillEnds() throws {
        let session = try EditKit.session(two)
        let editor = try PageEditor(session, 0)
        let before = try EditKit.glyphs(session)
        XCTAssertTrue(try editor.move([try blocks(editor)[1]], -10, 30).done)
        assertMoved(before, try EditKit.glyphs(session), { $0 >= 29 }, -10, 30)
    }

    func test_bothBlocksMoveByTheirOwnMatrices() throws {
        let session = try EditKit.session(two)
        let editor = try PageEditor(session, 0)
        let before = try EditKit.glyphs(session)
        let result = try editor.move(try editor.objects, 5, 5)
        XCTAssertEqual(result.changed, 2)
        assertMoved(before, try EditKit.glyphs(session), { _ in true }, 5, 5)
    }

    func test_textShownWithQuoteOperatorsAndKerningMoves() throws {
        let session = try EditKit.session("BT /F1 12 Tf 14 TL 50 700 Td [(Kern) -300 (ed) 120 (text)] TJ (second line) ' (third line) ' ET\nBT 1 0 0 1 50 300 Tm (other) Tj ET")
        let editor = try PageEditor(session, 0)
        let before = try EditKit.glyphs(session)
        let block = try blocks(editor)[0]
        XCTAssertTrue(try editor.move([block], 15, 5).done)
        assertMoved(before, try EditKit.glyphs(session), { $0 < before.count - 5 }, 15, 5)
    }

    func test_aBlockInTheMiddleOfARunIsLeftWhereItIs() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (left) Tj 100 0 Td (middle) Tj 100 0 Td (right) Tj ET")
        let editor = try PageEditor(session, 0)
        let before = try EditKit.glyphs(session)
        let middle = try XCTUnwrap(try editor.objects.compactMap { $0 as? TextObject }.first { $0.text.contains("middle") })
        XCTAssertTrue(try editor.move([middle], 0, -50).done)
        assertMoved(before, try EditKit.glyphs(session), { $0 >= 4 && $0 < 10 }, 0, -50)
    }

    func test_aBlockThatIsPartOfAStringIsMovedByCuttingTheString() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td [(Name:) -6000 (value) -250 (here)] TJ 0 -14 Td (next line) Tj ET")
        let editor = try PageEditor(session, 0)
        let before = try EditKit.glyphs(session)
        let cells = try editor.objects.compactMap { $0 as? TextObject }.filter { $0.bounds.top > 690 }.sorted { $0.bounds.left < $1.bounds.left }
        XCTAssertEqual(cells.count, 2)
        let result = try editor.move([cells[1]], 0, -60)
        XCTAssertTrue(result.done, result.skipped.map { $0.reason }.joined(separator: ", "))
        let after = try EditKit.glyphs(session)
        XCTAssertEqual(before.count, after.count)
        for i in 0..<min(before.count, after.count) {
            let moved = i >= 5 && i < 14
            XCTAssertEqual(after[i].x, before[i].x, accuracy: 0.005)
            XCTAssertEqual(after[i].y, before[i].y + (moved ? -60 : 0), accuracy: 0.005)
        }
    }

    func test_scalingAndRotatingATextBlockTransformsEachGlyph() throws {
        let session = try EditKit.session("BT /F1 12 Tf 100 700 Td (turn me) Tj ET")
        let editor = try PageEditor(session, 0)
        let box = try editor.objects[0].bounds
        XCTAssertTrue(try editor.rotate(try editor.objects, 90).done)
        let glyphs = try EditKit.glyphs(session)
        // Turned a quarter, the baseline runs up the page.
        XCTAssertTrue(glyphs[glyphs.count - 1].y > glyphs[0].y + 10)
        XCTAssertEqual(glyphs[0].x, glyphs[glyphs.count - 1].x, accuracy: 0.005)
        XCTAssertEqual(glyphs.map { $0.text }.joined(), "turn me")
        let center = try PageEditor(session, 0).objects[0].bounds
        XCTAssertEqual((box.left + box.right) / 2, (center.left + center.right) / 2, accuracy: 0.05)
        XCTAssertEqual((box.bottom + box.top) / 2, (center.bottom + center.top) / 2, accuracy: 0.05)
    }

    func test_textWithAnOpenQLevelIsRefusedNotBroken() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (hello) Tj q ET Q BT 0 -14 Td (world) Tj ET")
        let editor = try PageEditor(session, 0)
        let before = EditKit.latin(session)
        let hello = try XCTUnwrap(try editor.objects.compactMap { $0 as? TextObject }.first { $0.text.hasPrefix("hello") })
        let result = try editor.move([hello], 10, 10)
        XCTAssertFalse(result.done)
        XCTAssertEqual(try assertSingle(result.skipped).reason, EditingText.unbalanced)
        XCTAssertEqual(before, EditKit.latin(session))
        XCTAssertFalse(session.canUndo)
    }

    func test_deleteTakesABlockOutAndLeavesTheOthers() throws {
        let session = try EditKit.session(two)
        let editor = try PageEditor(session, 0)
        XCTAssertTrue(try editor.delete([try blocks(editor)[0]]).done)
        XCTAssertEqual(DotNetText.trim(try EditKit.text(session)), "Block two")
        XCTAssertEqual(try EditKit.glyphs(session)[0].x, 50)
    }
}
