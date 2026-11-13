import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/BidiTests.cs: the same cases.

final class BidiTests: XCTestCase {
    // Tests/Fixtures/golden/bidi/bidi-character.txt, lines of the Unicode conformance file; the C# suite reads the same file.
    func testCuratedConformanceLinesPass() throws {
        var checkedLines = 0
        for line in try Golden.input("bidi", "bidi-character.txt").split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let f = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            let cps = f[0].split(separator: " ").map { Int($0, radix: 16)! }
            var text = ""
            var firstUnit: [Int] = []
            var count = 0
            for cp in cps {
                firstUnit.append(count)
                let s = String(UnicodeScalar(UInt32(cp))!)
                text += s
                count += s.utf16.count
            }
            let direction = Int(f[1])!
            let para = BidiParagraph(text, baseLevel: direction == 2 ? BidiParagraph.auto : direction)
            XCTAssertEqual(Int(f[2])!, para.level, String(line))

            let levels = para.lineLevels(0, count)
            let actualLevels = firstUnit.map { levels[$0] < 0 ? "x" : String(levels[$0]) }.joined(separator: " ")
            XCTAssertEqual(f[3], actualLevels, String(line))

            var unitToIndex: [Int: Int] = [:]
            for (i, u) in firstUnit.enumerated() { unitToIndex[u] = i }
            let order = para.visualOrder(0, count).compactMap { unitToIndex[$0] }.map(String.init).joined(separator: " ")
            XCTAssertEqual(f[4], order, String(line))
            checkedLines += 1
        }
        XCTAssertGreaterThanOrEqual(checkedLines, 250)
    }

    private func visual(_ text: String, _ baseLevel: Int = BidiParagraph.auto) -> String {
        let units = Array(text.utf16)
        let para = BidiParagraph(text, baseLevel: baseLevel)
        return String(utf16CodeUnits: para.visualOrder(0, units.count).map { units[$0] }, count: units.count)
    }

    func testAHebrewWordIsReversedAndNumbersKeepTheirOrder() {
        XCTAssertEqual(visual("\u{05D0}\u{05D1}\u{05D2}"), "\u{05D2}\u{05D1}\u{05D0}")
        XCTAssertEqual(visual("\u{05D0}\u{05D1} 12"), "12 \u{05D1}\u{05D0}")
    }

    func testTheParagraphLevelComesFromTheFirstStrongCharacter() {
        XCTAssertEqual(BidiParagraph("123 \u{0627}").level, 1)
        XCTAssertEqual(BidiParagraph("abc \u{0627}").level, 0)
        XCTAssertEqual(BidiParagraph("123").level, 0)
        XCTAssertEqual(BidiParagraph("abc", baseLevel: 1).level, 1)
        XCTAssertEqual(BidiParagraph("\u{2067}\u{05D0}\u{2069}a").level, 0)
    }

    func testTrailingSpacesTakeTheParagraphLevelOnTheLine() {
        let para = BidiParagraph("\u{202E}ab  ", baseLevel: 0)
        XCTAssertEqual(para.levels, [-1, 1, 1, 1, 1])
        XCTAssertEqual(para.lineLevels(0, 5), [-1, 1, 1, 0, 0])
        XCTAssertEqual(para.visualOrder(0, 5), [2, 1, 3, 4])
    }

    func testALineCutInTheMiddleResolvesItsOwnTrailingSpace() {
        let para = BidiParagraph("\u{05D0} \u{05D1}", baseLevel: 0)
        XCTAssertEqual(para.lineLevels(0, 2), [1, 0])
    }

    func testASurrogatePairIsOneCharacterAndStaysInOrder() {
        // U+10800 CYPRIOT SYLLABLE A is right to left.
        let text = "a \u{10800}\u{10801}"
        let para = BidiParagraph(text)
        XCTAssertEqual(para.levels, [0, 0, 1, 1, 1, 1])
        XCTAssertEqual(para.visualOrder(0, text.utf16.count), [0, 1, 4, 5, 2, 3])
    }

    func testMirroringAndPairedBracketsComeFromTheTables() {
        XCTAssertEqual(BidiData.mirror(0x28), 0x29)
        XCTAssertEqual(BidiData.mirror(0x3E), 0x3C)
        XCTAssertEqual(BidiData.mirror(0x61), 0x61)
        var paired = BidiData.pairedBracket(0x28)
        XCTAssertEqual(paired.bracket, 0x29)
        XCTAssertTrue(paired.opening)
        paired = BidiData.pairedBracket(0x5D)
        XCTAssertEqual(paired.bracket, 0x5B)
        XCTAssertFalse(paired.opening)
        XCTAssertEqual(BidiData.pairedBracket(0x61).bracket, 0)
        XCTAssertEqual(BidiData.typeOf(0x0627), .al)
        XCTAssertEqual(BidiData.typeOf(0x05D0), .r)
        XCTAssertEqual(BidiData.typeOf(0x0661), .an)
        XCTAssertEqual(BidiData.typeOf(0x08A0), .al)
        XCTAssertEqual(BidiData.typeOf(0x110000), .l)
    }

    func testABracketPairInsideAnRtlRunTakesItsDirection() {
        XCTAssertEqual(visual("\u{05D0} (a) \u{05D1}").utf16.count, "\u{05D1} (a) \u{05D0}".utf16.count)
        let para = BidiParagraph("\u{05D0}(b)\u{05D1}", baseLevel: 1)
        XCTAssertEqual(para.levels, [1, 1, 2, 1, 1])
    }

    func testAMissingOrExtraFormattingCharacterIsHarmless() {
        let para = BidiParagraph("a\u{202C}\u{2069}b\u{202B}", baseLevel: 0)
        XCTAssertEqual(para.levels, [0, -1, 0, 0, -1])
    }

    func testDeeplyNestedEmbeddingsAndIsolatesStopAtTheLimit() {
        let deep = String(repeating: "\u{202B}\u{2066}", count: 200) + "a"
        let para = BidiParagraph(deep, baseLevel: 0)
        let top = para.levels.max()!
        XCTAssertTrue(top >= 0 && top <= 126)
        let brackets = String(repeating: "(", count: 5000) + "\u{05D0}" + String(repeating: ")", count: 5000)
        let n = brackets.utf16.count
        XCTAssertEqual(BidiParagraph(brackets, baseLevel: 0).visualOrder(0, n).count, n)
    }

    func testALongParagraphResolvesQuickly() {
        let text = String(repeating: "abc \u{05D0}\u{05D1}\u{05D2} 123 (x) ", count: 20000)
        let start = Date()
        let para = BidiParagraph(text, baseLevel: 0)
        _ = para.visualOrder(0, text.utf16.count)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
