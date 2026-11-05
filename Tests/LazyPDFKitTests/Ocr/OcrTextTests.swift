import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Ocr/OcrTextTests.cs: the same cases. The random words of
// ManyWordsAreOrderedInReasonableTime come from a small generator of the test, not System.Random.

final class OcrTextTests: XCTestCase {
    private func w(_ text: String, _ x: Double, _ y: Double, _ width: Double = 40, _ height: Double = 10) -> OcrWord {
        OcrKit.word(text, x, y, width, height)
    }

    func test_wordsOfARowJoinLeftToRightWhateverTheirOrder() throws {
        let lines = OcrText.lines([w("world", 60, 100), w("Hello", 10, 100)])
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.text, "Hello world")
        XCTAssertEqual(line.words.map { $0.text }, ["Hello", "world"])
        XCTAssertEqual(line.box, OcrBox(10, 100, 90, 10))
    }

    func test_farApartCellsOfARowAreSeparatedByATab() {
        let lines = OcrText.lines([w("Soup", 10, 100), w("4.50", 300, 100)])
        XCTAssertEqual(lines.map { $0.text }, ["Soup\t4.50"])
    }

    func test_linesAreReadTopToBottomAndColumnsOneAfterTheOther() {
        var words: [OcrWord] = []
        for row in 0..<4 {
            let y = Double(row * 14)
            words.append(w("L\(row)a", 10, 100 + y))
            words.append(w("L\(row)b", 55, 100 + y))
            words.append(w("R\(row)a", 300, 107 + y))
            words.append(w("R\(row)b", 345, 107 + y))
        }
        words.reverse()
        let lines = OcrText.lines(words)
        XCTAssertEqual(lines.map { $0.text }, ["L0a L0b", "L1a L1b", "L2a L2b", "L3a L3b", "R0a R0b", "R1a R1b", "R2a R2b", "R3a R3b"])
    }

    func test_columnsThatShareTheirRowsAreATableReadRowByRow() {
        var words: [OcrWord] = []
        for row in 0..<3 {
            let y = Double(row * 14)
            words.append(w("dish\(row)", 10, 100 + y))
            words.append(w("\(row).50", 300, 100 + y))
        }
        XCTAssertEqual(OcrText.lines(words).map { $0.text }, ["dish0\t0.50", "dish1\t1.50", "dish2\t2.50"])
    }

    func test_paragraphsSplitAtGapsAndJoinWrappedLines() {
        let page = OcrPage.of([
            w("Alpha", 10, 10, 280), w("beta", 10, 22, 280), w("gamma-", 10, 34, 280), w("delta", 10, 46, 200),
            w("Second", 10, 90, 280), w("paragraph", 10, 102, 100),
        ], 300, 200)
        let paragraphs = OcrText.paragraphs(page)
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.first?.text, "Alpha beta gammadelta")
        XCTAssertEqual(paragraphs.last?.text, "Second paragraph")
        XCTAssertEqual(OcrText.pageText(page), "Alpha\nbeta\ngamma-\ndelta\n\nSecond\nparagraph")
    }

    func test_plainTextSeparatesPagesAndIsEmptyWithoutWords() {
        let one = OcrPage.of([w("One", 10, 10)], 100, 100)
        let empty = OcrPage.of([], 100, 100)
        XCTAssertEqual(OcrText.plainText([one, empty]), "One\n\n\n\n")
        XCTAssertEqual(OcrText.plainText([empty, empty]), "")
    }

    func test_emptyAndFlatWordsAreDropped() {
        let lines = OcrText.lines([w("", 10, 10), w("  ", 10, 30), w("flat", 10, 50, 40, 0), w("neg", 10, 70, -5, 10), w("ok", 10, 90)])
        XCTAssertEqual(lines.map { $0.text }, ["ok"])
    }

    func test_controlCharactersBecomeSpaces() {
        XCTAssertEqual(OcrText.cleanLine("  a\u{0}\u{1}b\t c\u{2028} "), "a b\t c")
    }

    func test_manyWordsAreOrderedInReasonableTime() {
        var state: UInt64 = 7
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        var words: [OcrWord] = []
        for i in 0..<4000 { words.append(w("w\(i)", Double(next(600)), Double(next(800)))) }
        let start = Date()
        let lines = OcrText.lines(words)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 20, "\(elapsed) seconds")
        XCTAssertEqual(lines.reduce(0) { $0 + $1.words.count }, 4000)
    }

    func test_staircaseOfWordsStopsAtTheDepthLimit() {
        let words = (0..<600).map { w("s\($0)", Double($0 * 100), Double($0 * 30)) }
        let lines = OcrText.lines(words)
        XCTAssertEqual(lines.reduce(0) { $0 + $1.words.count }, 600)
    }
}
