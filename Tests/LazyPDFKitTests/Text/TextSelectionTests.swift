import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextSelectionTests.cs: the same cases.

final class TextSelectionTests: TextTestCase {
    // Glyph i of the first line is at 100 + 5 i; the lines are 12 points apart.
    private func sample() throws -> TextPage {
        try text(line(100, 700, "hello brave world") + line(100, 688, "second line here") + line(100, 676, "third"))
    }

    func test_aDragSelectsFromCaretToCaret() throws {
        let page = try sample()
        let selection = TextSelection.between(page, 131, 702, 168, 702)
        XCTAssertEqual(selection.getText(), "brave wo")
        XCTAssertEqual(selection.ranges[0], TextRange(6, 14))
    }

    func test_theDragCanGoBackwards() throws {
        let page = try sample()
        XCTAssertEqual(TextSelection.between(page, 168, 702, 131, 702).getText(), "brave wo")
    }

    func test_aDragAcrossLinesTakesTheLineBreak() throws {
        let page = try sample()
        XCTAssertEqual(TextSelection.between(page, 161, 702, 133, 690).getText(), "world\nsecond")
    }

    func test_aPointOutsideTheTextStillFindsACaret() throws {
        let page = try sample()
        XCTAssertEqual(page.caretAt(10, 790), 0)
        XCTAssertEqual(page.caretAt(500, 10), page.chars.count)
        XCTAssertEqual(TextSelection.between(page, 0, 799, 599, 0).getText(), "hello brave world\nsecond line here\nthird")
    }

    func test_aRectangleTakesTheCharactersInsideIt() throws {
        let page = try sample()
        let selection = TextSelection.inRectangle(page, PdfRect(95, 685, 400, 698))
        XCTAssertEqual(selection.getText(), "second line here")
        let part = TextSelection.inRectangle(page, PdfRect(99, 685, 131, 698))
        XCTAssertEqual(part.getText(), "second")
    }

    func test_aRectangleWithoutTextIsEmpty() throws {
        let selection = TextSelection.inRectangle(try sample(), PdfRect(400, 100, 500, 200))
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.getText(), "")
        XCTAssertTrue(selection.quads().isEmpty)
    }

    func test_aDoubleClickSelectsAWordAndATripleClickALine() throws {
        let page = try sample()
        XCTAssertEqual(TextSelection.wordAt(page, 142, 702).getText(), "brave")
        XCTAssertEqual(TextSelection.lineAt(page, 142, 702).getText(), "hello brave world")
        XCTAssertEqual(TextSelection.wordAt(page, 101, 690).getText(), "second")
    }

    func test_aDoubleClickOnASpaceTakesTheNextWord() throws {
        let page = try sample()
        XCTAssertEqual(TextSelection.wordAt(page, 127.5, 702).getText(), "brave")
    }

    func test_quadsComeOnePerLine() throws {
        let page = try sample()
        let quads = TextSelection.between(page, 161, 702, 133, 690).quads()
        XCTAssertEqual(quads.count, 2)
        XCTAssertEqual(quads[0].bounds.left, 160, accuracy: 1e-6)
        XCTAssertEqual(quads[0].bounds.right, 185, accuracy: 1e-6)
        XCTAssertEqual(quads[1].bounds.left, 100, accuracy: 1e-6)
        XCTAssertEqual(quads[1].bounds.right, 130, accuracy: 1e-6)
        XCTAssertTrue(quads[0].bounds.bottom > quads[1].bounds.top - 1)
    }

    func test_quadsLeaveOutSpacesAtTheEnds() throws {
        let page = try sample()
        let quads = page.quads(TextRange(5, 12))
        XCTAssertEqual(quads.count, 1)
        XCTAssertEqual(quads[0].bounds.left, 130, accuracy: 1e-6)
        XCTAssertEqual(quads[0].bounds.right, 155, accuracy: 1e-6)
    }

    func test_quadsOfRotatedTextAreRotated() throws {
        let page = try text("BT /F1 10 Tf 0 1 -1 0 300 300 Tm (up and away) Tj ET")
        let all = page.quads(TextRange(0, page.chars.count))
        XCTAssertEqual(all.count, 1)
        let q = try XCTUnwrap(all.first)
        XCTAssertEqual(q.x0, q.x1, accuracy: 1e-6)
        XCTAssertTrue(q.y1 > q.y0)
        XCTAssertEqual(q.toQuadPoints().count, 8)
    }

    func test_aHitGivesTheNearestCharacterWordAndLine() throws {
        let page = try sample()
        let hit = try XCTUnwrap(page.hitTest(142, 702))
        XCTAssertEqual(hit.distance, 0)
        XCTAssertEqual(page.chars[hit.char].text, "a")
        XCTAssertEqual(page.words[hit.word].text, "brave")
        XCTAssertEqual(hit.line, 0)
        let near = try XCTUnwrap(page.hitTest(98, 702))
        XCTAssertEqual(near.char, 0)
        XCTAssertEqual(near.distance, 2, accuracy: 1e-6)
    }

    func test_aHitFartherThanTheLimitIsNull() throws {
        let page = try sample()
        XCTAssertNil(page.hitTest(400, 400, maxDistance: 20))
        XCTAssertNotNil(page.hitTest(400, 400))
        XCTAssertNil(try text("").hitTest(10, 10))
    }

    func test_theNearestLineWinsBetweenTwoLines() throws {
        let page = try sample()
        XCTAssertEqual(page.hitTest(150, 686)?.line, 1)
        XCTAssertEqual(page.hitTest(150, 697)?.line, 0)
    }

    func test_ligaturesAreSelectedWhole() throws {
        let page = try text(line(100, 700, #"\001nd"#), "", (1, "fi"))
        let selection = TextSelection.between(page, 102, 702, 112, 702)
        XCTAssertEqual(TextSelection.wordAt(page, 101, 702).getText(), "find")
        XCTAssertEqual(page.getText(TextRange(0, 1)), "fi")
        XCTAssertFalse(selection.isEmpty)
    }

    func test_selectionTextCanJoinHyphens() throws {
        let page = try text(line(100, 700, "an informa-") + line(100, 688, "tion line"))
        let all = TextSelection.of(page, TextRange(0, page.chars.count))
        XCTAssertEqual(all.getText(), "an informa-\ntion line")
        XCTAssertEqual(all.getText(joinHyphens: true), "an information line")
    }
}
