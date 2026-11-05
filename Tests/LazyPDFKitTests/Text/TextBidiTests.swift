import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextBidiTests.cs: the same cases.

final class TextBidiTests: TextTestCase {
    private let hebrew: [(Int, String)] = [
        (1, "\u{05D0}"), (2, "\u{05D1}"), (3, "\u{05D2}"), (4, "\u{05D3}"), (5, "\u{05D4}"), (6, "\u{05D5}"),
        (7, "\u{FEDF}"), (8, "\u{FE8E}"),
    ]

    private func hebrewText(_ content: String) throws -> TextPage {
        try TextTestPdf.text(content, "", hebrew)
    }

    func test_aHebrewWordShownRightToLeftReadsInLogicalOrder() throws {
        let page = try hebrewText(line(100, 700, #"\003\002\001"#))
        XCTAssertEqual(page.text, "\u{05D0}\u{05D1}\u{05D2}")
        for c in page.chars { XCTAssertTrue(c.isRtl) }
        XCTAssertTrue(page.lines[0].isRtl)
    }

    func test_aLatinSentenceWithAHebrewWordKeepsItsDirection() throws {
        let page = try hebrewText(line(100, 700, #"abc \003\002\001 def"#))
        XCTAssertEqual(page.text, "abc \u{05D0}\u{05D1}\u{05D2} def")
        XCTAssertFalse(page.lines[0].isRtl)
    }

    func test_aRightToLeftSentenceReadsFromTheRight() throws {
        let page = try hebrewText(line(100, 700, #"abc \006\005\004 \003\002\001"#))
        XCTAssertEqual(page.text, "\u{05D0}\u{05D1}\u{05D2} \u{05D3}\u{05D4}\u{05D5} abc")
        XCTAssertTrue(page.lines[0].isRtl)
    }

    func test_numbersInRightToLeftTextKeepTheirDigitOrder() throws {
        let page = try hebrewText(line(100, 700, #"12.5 \003\002\001"#))
        XCTAssertEqual(page.text, "\u{05D0}\u{05D1}\u{05D2} 12.5")
    }

    func test_bracketsAreMirroredBackInRightToLeftRuns() throws {
        let page = try hebrewText(line(100, 700, #"\(\003\002\001\)"#))
        XCTAssertEqual(page.text, "(\u{05D0}\u{05D1}\u{05D2})")
    }

    func test_arabicPresentationFormsAreFoldedToLetters() throws {
        let page = try hebrewText(line(100, 700, #"\010\007"#))
        XCTAssertEqual(page.text, "\u{0644}\u{0627}")
    }

    func test_rightToLeftColumnsAreReadRightFirst() throws {
        let right = (0..<4).map { line(330, 700 - Double($0) * 12, #"\001\002\003 \001\002\003 \001\002\003 \001\002\003 \001\002\003"#) }.joined()
        let left = (0..<4).map { line(50, 700 - Double($0) * 12, #"\004\005\006 \004\005\006 \004\005\006 \004\005\006 \004\005\006"#) }.joined()
        let page = try hebrewText(left + right)
        XCTAssertTrue(page.lines[0].bounds.left > 300)
        XCTAssertTrue(page.lines[4].bounds.left < 100)
    }

    func test_aCaretInRightToLeftTextMovesLeftwardsWithTheIndex() throws {
        let page = try hebrewText(line(100, 700, #"\003\002\001"#))
        // Logical first character is the rightmost glyph, drawn from 110 to 115.
        XCTAssertEqual(page.chars[0].quad.x1, 115, accuracy: 1e-6)
        XCTAssertEqual(page.caretAt(114, 702), 0)
        XCTAssertEqual(page.caretAt(111, 702), 1)
        XCTAssertEqual(page.caretAt(99, 702), 3)
    }

    func test_aLongRunOfNeutralsIsResolvedInLinearTime() throws {
        for neutral in ["%", "."] {
            let content = "BT /F1 0.001 Tf 100 700 Td (" + String(repeating: neutral, count: 100_000) + #"\001) Tj ET"#
            let page = try hebrewText(content)
            XCTAssertTrue(page.text.hasPrefix("\u{05D0}"), neutral)
        }
    }
}
