import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/PageLabelTests.cs: the same cases.

final class PageLabelTests: XCTestCase {
    private func labels(_ pages: Int, _ ranges: PageLabelRange...) -> [String] {
        (0..<pages).map { PdfPageLabels.label(ranges, $0) }
    }

    func test_noRangesNumberPagesFromOne() {
        XCTAssertEqual(labels(3), ["1", "2", "3"])
    }

    func test_romanFrontMatterThenDecimalWithPrefix() {
        let result = labels(8, PageLabelRange(0, .lowerRoman), PageLabelRange(3, .decimal), PageLabelRange(6, .decimal, "A-", 10))
        XCTAssertEqual(result, ["i", "ii", "iii", "1", "2", "3", "A-10", "A-11"])
    }

    func test_upperRoman() {
        let cases: [(Int, String)] = [(1, "I"), (4, "IV"), (9, "IX"), (14, "XIV"), (40, "XL"), (94, "XCIV"), (1994, "MCMXCIV"), (3999, "MMMCMXCIX")]
        for (number, expected) in cases {
            XCTAssertEqual(PdfPageLabels.label([PageLabelRange(0, .upperRoman, "", number)], 0), expected, "\(number)")
        }
    }

    func test_lowerLetters() {
        let cases: [(Int, String)] = [(1, "a"), (26, "z"), (27, "aa"), (28, "bb"), (52, "zz"), (53, "aaa")]
        for (number, expected) in cases {
            XCTAssertEqual(PdfPageLabels.label([PageLabelRange(0, .lowerLetters, "", number)], 0), expected, "\(number)")
            XCTAssertEqual(PdfPageLabels.label([PageLabelRange(0, .upperLetters, "", number)], 0), expected.uppercased(), "\(number)")
        }
    }

    func test_prefixOnlyRange() {
        XCTAssertEqual(labels(3, PageLabelRange(0, .none, "Cover"), PageLabelRange(2)), ["Cover", "Cover", "1"])
    }

    func test_rangeBeforeFirstStartFallsBackToDecimal() {
        XCTAssertEqual(labels(3, PageLabelRange(2, .none, "x")), ["1", "2", "x"])
    }

    func test_readsHandWrittenLabels() throws {
        let document = try StructureFixtures.file("/PageLabels <</Nums [0 <</S /r>> 1 <</S /D /P (p. ) /St 5>> 2 <</S /Q>>]>>")
        let ranges = PdfPageLabels.read(document)
        XCTAssertEqual(ranges.map { $0.style }, [.lowerRoman, .decimal, .none])
        XCTAssertEqual(PdfPageLabels.labels(document), ["i", "p. 5", ""])
    }

    func test_readIgnoresJunk() throws {
        let document = try StructureFixtures.file("/PageLabels <</Nums [-3 <</S /D>> 0 5 1 <</S /D /St 0>> 2 <</S /D /St -4>>]>>")
        let ranges = PdfPageLabels.read(document)
        XCTAssertEqual(ranges.map { $0.startPage }, [1, 2])
        XCTAssertEqual(ranges.map { $0.firstNumber }, [1, 1])
    }

    func test_writeSortsAndAddsRangeAtZero() throws {
        let document = try StructureFixtures.open(6)
        try PdfPageLabels.write(document, [PageLabelRange(4, .upperLetters), PageLabelRange(2, .decimal, "S", 3), PageLabelRange(2, .decimal, "T", 3)])
        let reopened = try StructureFixtures.reopen(document)
        let ranges = PdfPageLabels.read(reopened)
        XCTAssertEqual(ranges.map { $0.startPage }, [0, 2, 4])
        XCTAssertEqual(PdfPageLabels.labels(reopened), ["1", "2", "T3", "T4", "A", "B"])
    }

    func test_writeReplacesAndRemoves() throws {
        let document = try StructureFixtures.open(3)
        try PdfPageLabels.write(document, [PageLabelRange(0, .lowerRoman)])
        try PdfPageLabels.write(document, [PageLabelRange(0, .upperRoman), PageLabelRange(1)])
        XCTAssertEqual(PdfPageLabels.labels(document), ["I", "1", "2"])
        try PdfPageLabels.write(document, [])
        XCTAssertNil(document.catalog["PageLabels"])
        XCTAssertEqual(PdfPageLabels.labels(document), ["1", "2", "3"])
    }

    func test_manyRangesBecomeATree() throws {
        let document = try StructureFixtures.open(500)
        try PdfPageLabels.write(document, (0..<500).map { PageLabelRange($0, .decimal, "s\($0)-") })
        let reopened = try StructureFixtures.reopen(document)
        XCTAssertEqual(PdfPageLabels.labels(reopened)[499], "s499-1")
        XCTAssertNotNil(reopened.dict(reopened.catalog, "PageLabels")?["Kids"])
    }

    func test_writtenLabelsWithNonLatinPrefix() throws {
        let document = try StructureFixtures.open(2)
        try PdfPageLabels.write(document, [PageLabelRange(0, .decimal, "\u{416}-")])
        XCTAssertEqual(PdfPageLabels.labels(try StructureFixtures.reopen(document))[1], "\u{416}-2")
    }

    func test_findsAPageByLabel() throws {
        let document = try StructureFixtures.open(6)
        try PdfPageLabels.write(document, [PageLabelRange(0, .lowerRoman), PageLabelRange(2, .decimal)])
        XCTAssertEqual(PdfPageLabels.find(document, "ii"), 1)
        XCTAssertEqual(PdfPageLabels.find(document, "II"), 1)
        XCTAssertEqual(PdfPageLabels.find(document, "4"), 5)
        XCTAssertNil(PdfPageLabels.find(document, "zz"))
    }

    // Numbers the C# tests do not reach: past the cap on a long run of letters or numerals, and no trap at the ends.
    func test_hugeNumbersAreCapped() {
        let big = PdfPageLabels.label([PageLabelRange(0, .lowerLetters, "", Int(Int32.max))], 0)
        XCTAssertEqual(big.count, 4096)
        let roman = PdfPageLabels.label([PageLabelRange(0, .lowerRoman, "", Int(Int32.max))], 0)
        XCTAssertTrue(roman.count >= 4096 && roman.count < 4100, "\(roman.count)")
        XCTAssertEqual(PdfPageLabels.label([], Int.max), String(Int.min))
    }

    func test_findComparesOrdinally() throws {
        let document = try StructureFixtures.open(3)
        try PdfPageLabels.write(document, [PageLabelRange(0, .none, "K\u{131}s\u{131}m"), PageLabelRange(1, .none, "\u{1F80}"), PageLabelRange(2, .none, "\u{E9}")])
        XCTAssertNil(PdfPageLabels.find(document, "KISIM"))
        XCTAssertEqual(PdfPageLabels.find(document, "K\u{131}S\u{131}M"), 0)
        XCTAssertEqual(PdfPageLabels.find(document, "\u{1F88}"), 1)
        XCTAssertEqual(PdfPageLabels.find(document, "\u{C9}"), 2)
        XCTAssertNil(PdfPageLabels.find(document, "e\u{301}"))
    }
}
