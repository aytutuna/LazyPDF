import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/ViewerSelectionTests.cs: the selected text as carets, across pages.

@MainActor
final class ViewerSelectionTests: XCTestCase {
    private func chars(_ page: Int) -> Int { 10 * (page + 1) }

    func test_caretsAreOrderedByPageThenIndex() async {
        XCTAssertTrue(Caret(0, 50) < Caret(1, 0))
        XCTAssertTrue(Caret(2, 5) > Caret(2, 4))
        XCTAssertFalse(Caret(1, 1) < Caret(1, 1) || Caret(1, 1) > Caret(1, 1))
    }

    func test_aNewSelectionIsEmpty() async {
        let selection = ViewerSelection()

        XCTAssertTrue(selection.isEmpty)
        XCTAssertTrue(selection.ranges(chars).isEmpty)
    }

    func test_aSelectionOnOnePageIsTheStretchBetweenTheCarets() async {
        let selection = ViewerSelection()
        selection.set(Caret(1, 12), Caret(1, 3))

        let ranges = selection.ranges(chars)

        XCTAssertEqual(ranges.map { [$0.page, $0.range.start, $0.range.end] }, [[1, 3, 12]])
        XCTAssertEqual(selection.start, Caret(1, 3))
        XCTAssertEqual(selection.end, Caret(1, 12))
    }

    func test_aSelectionAcrossPagesTakesTheEndOfTheFirstAllOfTheMiddleAndTheStartOfTheLast() async {
        let selection = ViewerSelection()
        selection.set(Caret(0, 4), Caret(3, 7))

        let ranges = selection.ranges(chars)

        XCTAssertEqual(ranges.map { [$0.page, $0.range.start, $0.range.end] }, [[0, 4, 10], [1, 0, 20], [2, 0, 30], [3, 0, 7]])
    }

    func test_anIndexPastTheTextMeansItsEnd() async {
        let selection = ViewerSelection()
        selection.selectAll(3)

        let ranges = selection.ranges(chars)

        XCTAssertEqual(ranges.map { [$0.page, $0.range.start, $0.range.end] }, [[0, 0, 10], [1, 0, 20], [2, 0, 30]])
    }

    func test_aPageWithNoTextAddsNothing() async {
        let selection = ViewerSelection()
        selection.set(Caret(0, 0), Caret(2, 5))

        let ranges = selection.ranges { $0 == 1 ? 0 : 10 }

        XCTAssertEqual(ranges.map { $0.page }, [0, 2])
    }

    func test_onGivesTheStretchOfOnePageOrNothing() async {
        let selection = ViewerSelection()
        selection.set(Caret(1, 5), Caret(2, 8))

        XCTAssertEqual(selection.on(1, 20), LazyPDFKit.TextRange(5, 20))
        XCTAssertEqual(selection.on(2, 30), LazyPDFKit.TextRange(0, 8))
        XCTAssertNil(selection.on(0, 10))
        XCTAssertNil(selection.on(3, 10))
        XCTAssertTrue(selection.covers(2))
        XCTAssertFalse(selection.covers(0))
    }

    func test_extendingKeepsTheAnchorAndMovesTheFocus() async {
        let selection = ViewerSelection()
        selection.set(Caret(0, 5), Caret(0, 5))

        selection.extend(Caret(0, 2))

        XCTAssertEqual(selection.anchor, Caret(0, 5))
        XCTAssertEqual(selection.focus, Caret(0, 2))
        XCTAssertEqual(selection.start, Caret(0, 2))
    }

    func test_changesAreAnnouncedOnceAndOnlyWhenTheyChangeSomething() async {
        let selection = ViewerSelection()
        var raised = 0
        selection.onChanged = { raised += 1 }

        selection.set(Caret(0, 1), Caret(0, 4))
        selection.set(Caret(0, 1), Caret(0, 4))
        selection.clear()
        selection.clear()

        XCTAssertEqual(raised, 2)
        XCTAssertTrue(selection.isEmpty)
    }
}
