import XCTest
import LazyPDFKit
@testable import LazyPDFApp

final class PageTextMapTests: XCTestCase {
    private func map(_ text: String) async throws -> PageTextMap {
        let bytes = try PdfFromText.create(text, fonts: FakeFonts()).bytes
        let source = try await XCTUnwrapAsync(await TextSource.open(bytes, password: nil))
        return PageTextMap(try await XCTUnwrapAsync(await source.get(0)))
    }

    private let sample = "First line of text.\n   indented second line  \n\nA new paragraph here.\nAnd its last line."

    func test_theTextIsThePagesOwn() async throws {
        for text in ["one", "a  b   c", "x\n\n\ny", "First line.\n\nA new paragraph.\nAnd its last line."] {
            let found = try await map(text)

            XCTAssertEqual(found.text, found.page.text)
            XCTAssertEqual(found.length, found.page.text.utf16.count)
        }
    }

    func test_aLineThatStartsWithASpaceStillStartsAfterABreak() async throws {
        let found = try await map("one\n   indented\n two")

        XCTAssertEqual(found.text, "one\nindented\ntwo")
        XCTAssertEqual(found.string(in: found.units(ofLine: 1)), "indented")
        XCTAssertEqual(found.line(atOffset: found.units(ofLine: 1).lowerBound), 1)
    }

    func test_everyKeptCharacterIsFoundWhereTheMapSaysAndComesBack() async throws {
        let found = try await map(sample)

        for (i, c) in found.page.chars.enumerated() where !c.isSpace && !c.text.isEmpty {
            XCTAssertEqual(found.string(in: found.units(ofChar: i)), c.text, "char \(i)")
            XCTAssertEqual(found.char(atOffset: found.offset(ofChar: i)), i)
        }
    }

    func test_aLineIsItsOwnTextWithoutTheBreakBeforeIt() async throws {
        let found = try await map(sample)

        XCTAssertGreaterThan(found.lineCount, 3)
        for (i, line) in found.page.lines.enumerated() {
            XCTAssertEqual(found.string(in: found.units(ofLine: i)), found.page.getText(line.range), "line \(i)")
        }
    }

    func test_aUnitInALineGivesThatLineAndABreakBelongsToTheLineBeforeIt() async throws {
        let found = try await map(sample)
        let second = found.units(ofLine: 1)

        XCTAssertEqual(found.line(atOffset: 0), 0)
        XCTAssertEqual(found.line(atOffset: second.lowerBound), 1)
        XCTAssertEqual(found.line(atOffset: second.upperBound - 1), 1)
        XCTAssertEqual(found.line(atOffset: second.lowerBound - 1), 0)
        XCTAssertEqual(found.line(atOffset: found.length), found.lineCount - 1)
    }

    func test_aRangeOfUnitsWidensToWholeCharacters() async throws {
        let found = try await map(sample)

        XCTAssertEqual(found.chars(in: 0..<5), LazyPDFKit.TextRange(0, 5))
        XCTAssertEqual(found.chars(in: 3..<3), LazyPDFKit.TextRange(3, 3))
        XCTAssertEqual(found.units(of: LazyPDFKit.TextRange(0, 5)), 0..<5)
        XCTAssertEqual(found.string(in: 0..<5), "First")
    }

    func test_anOffsetPastTheEndIsTheEndAndNothingTraps() async throws {
        let found = try await map(sample)
        let count = found.page.chars.count

        XCTAssertEqual(found.char(atOffset: found.length + 10), count)
        XCTAssertEqual(found.offset(ofChar: count + 5), found.length)
        XCTAssertEqual(found.string(in: -4..<found.length + 4), found.text)
        XCTAssertTrue(found.units(ofLine: 99).isEmpty)
    }

    func test_aPageWithoutTextIsEmpty() async throws {
        let found = try await map("")

        XCTAssertEqual(found.length, 0)
        XCTAssertEqual(found.lineCount, 0)
        XCTAssertEqual(found.char(atOffset: 0), 0)
        XCTAssertEqual(found.line(atOffset: 0), 0)
    }
}
