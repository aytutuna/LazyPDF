import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/AnchorDirectionTests.cs: the same cases.

final class AnchorDirectionTests: CompareTestCase {
    // Codes 1 to 6 are Hebrew letters; the text is set in visual order, so the first letter of a word is its rightmost glyph.
    private func make(_ line: String) throws -> PdfDocument {
        try TextTestPdf.page(TextTestPdf.line(100, 700, line), "", [(1, "א"), (2, "ב"), (3, "ג"), (4, "ד"), (5, "ה"), (6, "ו")])
    }

    func test_insertionBetweenHebrewWordsOfALeftToRightLineIsAnchoredAtTheLeftEdgeOfTheEarlierOne() throws {
        let before = try make(#"abc \004\003 \002\001 def"#)
        let after = try make(#"abc \004\003 \006\005 \002\001 def"#)
        let change = try single(try PdfComparer.compare(before, after).changes)
        XCTAssertEqual(change.kind, .added)
        // The earlier word is read first and drawn on the right, from 135 to 145; its end is its left edge.
        assertInRange(try single(change.oldQuads).bounds.left, 134, 136)
    }

    func test_insertionBetweenLatinWordsOfARightToLeftLineIsAnchoredAtTheRightEdgeOfTheEarlierOne() throws {
        let before = try make(#"\004\003\002\001 ab cd \004\003\002\001"#)
        let after = try make(#"\004\003\002\001 ab xy cd \004\003\002\001"#)
        let change = try single(try PdfComparer.compare(before, after).changes)
        XCTAssertEqual(change.kind, .added)
        // 'ab' is drawn from 125 to 135.
        assertInRange(try single(change.oldQuads).bounds.left, 134, 136)
    }
}
