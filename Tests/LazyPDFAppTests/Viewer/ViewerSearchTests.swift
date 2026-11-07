import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/ViewerSearchTests.cs: the search the find bar and the Search panel share, over the text
// of a file read for the viewer.

@MainActor
final class ViewerSearchTests: XCTestCase {
    private func pages(_ count: Int) throws -> [UInt8] {
        try TestPdfs.text(pages: count, line: "The quick brown fox jumps over the lazy dog.")
    }

    private func searching(_ bytes: [UInt8], startPage: Int = 0) -> ViewerSearch {
        ViewerSearch(source: { Task { await TextSource.open(bytes, password: nil) } }, startPage: { startPage })
    }

    func test_everyMatchOnEveryPageIsListedWithItsWords() async throws {
        let search = searching(try pages(3))

        await search.start("lazy dog", TextSearchOptions()).value

        XCTAssertEqual(search.hits.map { $0.page }, [0, 1, 2])
        XCTAssertTrue(search.hits.allSatisfy { $0.text == "lazy dog" })
        XCTAssertTrue(search.hits[0].before.hasSuffix("over the"))
        XCTAssertTrue(search.hits[0].after.hasPrefix("."))
        XCTAssertFalse(search.isRunning)
    }

    func test_theFirstCurrentHitIsTheFirstOneAtOrAfterTheStartPage() async throws {
        let search = searching(try pages(3), startPage: 1)

        await search.start("fox", TextSearchOptions()).value

        XCTAssertEqual(search.current, 1)
        XCTAssertEqual(search.hits[search.current].page, 1)
    }

    func test_searchingAgainAfterAnEditLeavesTheViewWhereItIs() async throws {
        let search = searching(try pages(3), startPage: 1)
        var moves = 0
        search.onCurrentChanged = { moves += 1 }
        await search.start("fox", TextSearchOptions()).value
        XCTAssertEqual(moves, 1)

        await search.restart().value

        XCTAssertEqual(moves, 1)
        XCTAssertEqual(search.hits.count, 3)
        XCTAssertGreaterThanOrEqual(search.current, 0)
    }

    func test_aStepAfterARestartGoesToTheHitAgain() async throws {
        let search = searching(try pages(3))
        await search.start("fox", TextSearchOptions()).value
        await search.restart().value
        var moves = 0
        search.onCurrentChanged = { moves += 1 }

        search.next()

        XCTAssertEqual(moves, 1)
    }

    func test_withNothingAfterTheStartPageTheFirstHitIsCurrent() async throws {
        let search = searching(try pages(2), startPage: 5)

        await search.start("fox", TextSearchOptions()).value

        XCTAssertEqual(search.current, 0)
    }

    func test_nextAndPreviousGoRoundTheHits() async throws {
        let search = searching(try pages(3))
        await search.start("fox", TextSearchOptions()).value
        var moved = 0
        search.onCurrentChanged = { moved += 1 }

        search.next()
        search.next()
        search.next()
        search.previous()

        XCTAssertEqual(search.current, 2)
        XCTAssertEqual(moved, 4)
    }

    func test_selectingAHitMakesItCurrent() async throws {
        let search = searching(try pages(3))
        await search.start("fox", TextSearchOptions()).value

        search.select(2)
        search.select(99)

        XCTAssertEqual(search.current, 2)
    }

    func test_optionsChangeWhatMatches() async throws {
        let search = searching(try pages(2))

        await search.start("LAZY", TextSearchOptions()).value
        let loose = search.hits.count
        await search.start("LAZY", TextSearchOptions(matchCase: true)).value
        let exact = search.hits.count
        await search.start("la", TextSearchOptions(wholeWord: true)).value
        let whole = search.hits.count
        await search.start("l.zy", TextSearchOptions(regex: true)).value
        let pattern = search.hits.count

        XCTAssertEqual([loose, exact, whole, pattern], [2, 0, 0, 2])
    }

    func test_aBadPatternIsReportedAndFindsNothing() async throws {
        let search = searching(try pages(1))

        await search.start("(", TextSearchOptions(regex: true)).value

        XCTAssertTrue(search.badPattern)
        XCTAssertTrue(search.hits.isEmpty)
        XCTAssertFalse(search.isRunning)
    }

    func test_anEmptyQueryClears() async throws {
        let search = searching(try pages(2))
        await search.start("fox", TextSearchOptions()).value

        await search.start("", TextSearchOptions()).value

        XCTAssertTrue(search.hits.isEmpty)
        XCTAssertEqual(search.current, -1)
        XCTAssertEqual(search.query, "")
    }

    func test_anotherSearchReplacesTheOneBefore() async throws {
        let bytes = try pages(2)
        let slow = Later<TextSource?>()
        var calls = 0
        let search = ViewerSearch(source: {
            calls += 1
            return calls == 1 ? Task { await slow.value } : Task { await TextSource.open(bytes, password: nil) }
        }, startPage: { 0 })

        let first = search.start("fox", TextSearchOptions())
        let second = search.start("dog", TextSearchOptions())
        await second.value
        slow.set(await TextSource.open(bytes, password: nil))
        await first.value

        XCTAssertEqual(search.query, "dog")
        XCTAssertEqual(search.hits.count, 2)
        XCTAssertTrue(search.hits.allSatisfy { $0.text == "dog" })
    }

    func test_aFileTheEngineCannotOpenGivesNoHits() async {
        let search = ViewerSearch(source: { Task { nil } }, startPage: { 0 })

        await search.start("fox", TextSearchOptions()).value

        XCTAssertTrue(search.hits.isEmpty)
        XCTAssertFalse(search.isRunning)
    }
}

/// A value that arrives later, for a test to hold a search back.
private final class Later<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: T?
    private var waiting: CheckedContinuation<T, Never>?
    private var isSet = false

    var value: T {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isSet, let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    waiting = continuation
                    lock.unlock()
                }
            }
        }
    }

    func set(_ value: T) {
        lock.lock()
        result = value
        isSet = true
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
