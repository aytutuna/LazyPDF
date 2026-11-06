import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/PageAlignTests.cs: the same cases.

final class PageAlignTests: CompareTestCase {
    private func pages(_ topics: String...) -> [[String]] { topics.map { page($0) } }

    func test_insertedPageShiftsTheRest() throws {
        let result = try compare(pages("a", "b", "c", "d"), pages("a", "b", "x", "c", "d"))
        XCTAssertEqual(shape(result), "0=0 1=1 +2 2=3 3=4")
        let change = try single(result.changes)
        XCTAssertEqual(change.kind, .added)
        XCTAssertEqual(change.area, .page)
        XCTAssertEqual(change.oldPage, -1)
        XCTAssertEqual(change.newPage, 2)
        XCTAssertTrue(change.oldQuads.isEmpty)
        _ = try single(change.newQuads)
        XCTAssertEqual(result.summary.pages, 1)
    }

    func test_removedPageIsReportedOnTheOldSide() throws {
        let result = try compare(pages("a", "b", "c", "d"), pages("a", "c", "d"))
        XCTAssertEqual(shape(result), "0=0 -1 2=1 3=2")
        let change = try single(result.changes)
        XCTAssertEqual(change.kind, .removed)
        XCTAssertEqual(change.oldPage, 1)
        XCTAssertEqual(change.newPage, -1)
        _ = try single(change.oldQuads)
    }

    func test_insertionAtTheStartAndEnd() throws {
        let result = try compare(pages("a", "b"), pages("x", "a", "b", "y"))
        XCTAssertEqual(shape(result), "+0 0=1 1=2 +3")
    }

    func test_movedPageIsPairedByContentNotNumber() throws {
        let result = try compare(pages("a", "b", "c", "d", "e"), pages("a", "c", "d", "e", "b"))
        XCTAssertEqual(result.pages.filter { !$0.moved && !$0.isAdded && !$0.isRemoved }.count, 4)
        let moved = try single(result.pages, where: { $0.moved })
        XCTAssertEqual(moved.oldIndex, 1)
        XCTAssertEqual(moved.newIndex, 4)
        let change = try single(result.changes)
        XCTAssertEqual(change.kind, .moved)
        XCTAssertEqual(change.area, .page)
    }

    func test_reorderedPagesComparedWithTheirPartnersHaveNoTextChanges() throws {
        let result = try compare(pages("a", "b", "c"), pages("c", "a", "b"))
        XCTAssertFalse(result.changes.contains { $0.area == .text })
        XCTAssertEqual(result.summary.pages, 1)
    }

    func test_editedPageStaysPairedThroughAnInsertion() throws {
        let before = [page("a"), page("b"), page("c")]
        var edited = page("b")
        edited[1] = "b line2 only a few words survive"
        let after = [page("a"), page("new"), edited, page("c")]
        let result = try compare(before, after)
        XCTAssertEqual(shape(result), "0=0 +1 1=2 2=3")
        XCTAssertTrue(result.changes.contains { $0.area == .text && $0.newPage == 2 })
    }

    func test_pageWithMostlyNewTextTakesItsPlaceInAGap() throws {
        let before = [page("a"), page("b"), page("c")]
        let after = [page("a"), page("zzz"), page("c")]
        let result = try compare(before, after)
        XCTAssertEqual(shape(result), "0=0 -1 +1 2=2")
    }

    func test_repeatedBlankPagesKeepTheirOrder() throws {
        let before: [[String]] = [page("a"), [], [], page("b"), []]
        let after: [[String]] = [page("a"), [], page("b"), []]
        let result = try compare(before, after)
        XCTAssertEqual(result.pages.filter { $0.isRemoved }.count, 1)
        XCTAssertEqual(result.pages.filter { $0.oldIndex >= 0 }.count, 5)
        XCTAssertEqual(result.pages.filter { $0.newIndex >= 0 }.count, 4)
    }

    func test_emptyDocumentsCompare() throws {
        let some = [page("a")]
        let result = try compare(some, [[]])
        XCTAssertEqual(result.newPageCount, 1)
    }

    func test_largeDocumentAlignsQuicklyWithInsertions() throws {
        let before = (0..<300).map { page("t\($0)", 8) }
        var after = before
        after.insert(page("fresh1", 8), at: 10)
        after.insert(page("fresh2", 8), at: 200)
        after.remove(at: 100)
        let start = Date()
        let result = try compare(before, after)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.pages.filter { $0.isAdded }.count, 2)
        XCTAssertEqual(result.pages.filter { $0.isRemoved }.count, 1)
        XCTAssertEqual(result.summary.pages, 3)
        XCTAssertLessThan(elapsed, 90, "\(elapsed) s")
    }

    func test_pagesEditedThroughoutStillPairInAFileTooLongForTheFullTable() throws {
        func words(_ page: Int, _ edited: Bool) -> String {
            (1...12).map { w in "p\(page)w\(w)" + (edited && w % 3 == 0 ? "x" : "") }.joined(separator: " ")
        }
        let before = (0..<201).map { [words($0, false)] }
        let after = [["fresh cover page"]] + (0..<201).map { [words($0, true)] }
        let result = try compare(before, after)
        XCTAssertEqual(result.pages.filter { !$0.isAdded && !$0.isRemoved }.count, 201)
        XCTAssertEqual(result.pages.filter { $0.isAdded }.count, 1)
        XCTAssertEqual(result.pages.filter { $0.isRemoved }.count, 0)
    }

    private func edited(_ page: Int) -> String {
        (1...12).map { w in "p\(page)w\(w)" + (w % 3 == 0 ? "x" : "") }.joined(separator: " ")
    }

    private func original(_ page: Int) -> String {
        (1...12).map { w in "p\(page)w\(w)" }.joined(separator: " ")
    }

    private func fresh(_ i: Int) -> String {
        "fresh cover \(i) " + (0..<12).map { w in "f\(i)w\(w)" }.joined(separator: " ")
    }

    func test_editedPagesPairWhateverTheOffsetInAGapOfEqualLength() throws {
        // 120 pages in front, 120 gone at the end: the true offset is beyond any band of 40000 cells around the diagonal.
        let before = (0..<201).map { [original($0)] }
        let after = (0..<120).map { [fresh($0)] } + (0..<81).map { [edited($0)] }
        let result = try compare(before, after)
        let paired = result.pages.filter { !$0.isAdded && !$0.isRemoved }
        XCTAssertEqual(paired.count, 81)
        for p in paired { XCTAssertEqual(p.newIndex, p.oldIndex + 120) }
        XCTAssertEqual(result.pages.filter { $0.isAdded }.count, 120)
        XCTAssertEqual(result.pages.filter { $0.isRemoved }.count, 120)
    }

    func test_editedPagesPairInAGapWhoseSidesDifferByMoreThanTheTableAllows() throws {
        let before = (0..<150).map { [original($0)] }
        let after = (0..<140).map { [fresh($0)] } + (0..<150).map { [edited($0)] }
        let result = try compare(before, after)
        let paired = result.pages.filter { !$0.isAdded && !$0.isRemoved }
        XCTAssertEqual(paired.count, 150)
        for p in paired { XCTAssertEqual(p.newIndex, p.oldIndex + 140) }
    }

    func test_scansWithNothingAlikePairByPositionInAGapTooLargeForTheFullTable() throws {
        let before = (0..<201).map { ["alpha\($0) beta\($0)"] }
        let after = (0..<201).map { ["gamma\($0) delta\($0)"] }
        let result = try compare(before, after)
        XCTAssertEqual(result.pages.filter { !$0.isAdded && !$0.isRemoved && $0.oldIndex == $0.newIndex }.count, 201)
    }

    func test_cancellationStopsTheRun() async throws {
        let a = try doc(pages("a", "b"))
        let task = Task { () throws -> ComparisonResult in
            while !Task.isCancelled { await Task.yield() }
            return try PdfComparer.compare(a, a)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }
}
