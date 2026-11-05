import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageLabelShiftTests.cs: the same cases.

final class PageLabelShiftTests: XCTestCase {
    // Pages 1 and 2 are numbered i, ii; pages 3 to 5 are numbered 5, 6, 7.
    private let labels = "/PageLabels <</Nums [0 <</S /r>> 2 <</S /D /St 5>>]>>"

    private struct Labelled: Equatable {
        let start: Int
        let style: String
        let st: Int?

        init(_ start: Int, _ style: String, _ st: Int?) {
            self.start = start
            self.style = style
            self.st = st
        }
    }

    private func ranges(_ document: PdfDocument) throws -> [Labelled] {
        let nums = try XCTUnwrap(document.array(document.dict(document.catalog, "PageLabels"), "Nums")).items
        var found: [Labelled] = []
        for i in stride(from: 0, to: nums.count, by: 2) {
            let label = try XCTUnwrap(document.resolve(nums[i + 1]) as? PdfDictionary)
            found.append(Labelled((nums[i] as? PdfNumber)?.integer ?? -1, document.name(label, "S") ?? "", document.integer(label, "St")))
        }
        return found
    }

    func test_rangesMoveUpWithTheirFirstPage() throws {
        let document = try PageTestFiles.open(5, labels)
        try PageOperations.delete(document, [0])
        XCTAssertEqual(try ranges(document), [Labelled(0, "r", 2), Labelled(1, "D", 5)])
    }

    func test_aRangeThatLosesItsFirstPagesStartsFurtherOn() throws {
        let document = try PageTestFiles.open(5, labels)
        try PageOperations.delete(document, [2, 3])
        XCTAssertEqual(try ranges(document), [Labelled(0, "r", nil), Labelled(2, "D", 7)])
    }

    func test_aRangeWithNoPageLeftIsDropped() throws {
        let document = try PageTestFiles.open(5, labels)
        try PageOperations.delete(document, [0, 1])
        XCTAssertEqual(try ranges(document), [Labelled(0, "D", 5)])
    }

    func test_aPageInTheMiddleOfARangeJustShortensIt() throws {
        let document = try PageTestFiles.open(5, labels)
        try PageOperations.delete(document, [3])
        XCTAssertEqual(try ranges(document), [Labelled(0, "r", nil), Labelled(2, "D", 5)])
    }

    func test_aLabelTreeWithKidsIsReadAndWrittenFlat() throws {
        let tree = "/PageLabels <</Kids [<</Limits [0 1] /Nums [0 <</S /r>>]>> <</Limits [2 4] /Nums [2 <</S /D>>]>>]>>"
        let document = try PageTestFiles.open(5, tree)
        try PageOperations.delete(document, [0])
        let root = try XCTUnwrap(document.dict(document.catalog, "PageLabels"))
        XCTAssertFalse(root.containsKey("Kids"))
        XCTAssertEqual(try ranges(document), [Labelled(0, "r", 2), Labelled(1, "D", nil)])
    }

    func test_labelsFollowAnInsertedPageAndStayWhereTheyAreWhenPagesMove() throws {
        let document = try PageTestFiles.open(5, labels)
        try PageOperations.reorder(document, [4, 3, 2, 1, 0])
        XCTAssertEqual(try ranges(document), [Labelled(0, "r", nil), Labelled(2, "D", 5)])
        try PageOperations.insertBlank(document, 2, 100, 100)
        XCTAssertEqual(try ranges(document), [Labelled(0, "r", nil), Labelled(3, "D", 5)])
    }

    func test_aDocumentWithoutLabelsGetsNone() throws {
        let document = try PageTestFiles.open(3)
        try PageOperations.delete(document, [0])
        try PageOperations.insertBlank(document, 0, 100, 100)
        XCTAssertNil(document.catalog["PageLabels"])
    }
}
