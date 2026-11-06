import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/TileCacheTests.cs: the pictures kept for the pages, least recently used first out once
// they pass the budget.

final class TileCacheTests: XCTestCase {
    // A 50 by 50 picture is 10,000 bytes.
    private struct Picture: PixelSized {
        let pixelWidth = 50
        let pixelHeight = 50
    }

    private func key(_ page: Int, _ column: Int = 0) -> TileKey {
        TileKey(page, 0, 1, column, 0, .none)
    }

    func test_aPictureAddedCanBeFoundAndCounted() {
        let cache = TileCache<Picture>(budget: 1_000_000)

        cache.add(key(1), Picture())

        XCTAssertTrue(cache.contains(key(1)))
        XCTAssertNotNil(cache.get(key(1)))
        XCTAssertEqual(cache.bytes, 10_000)
        XCTAssertEqual(cache.count, 1)
    }

    func test_theLeastRecentlyUsedGoFirstWhenTheBudgetIsPassed() {
        let cache = TileCache<Picture>(budget: 25_000)
        cache.add(key(1), Picture())
        cache.add(key(2), Picture())
        _ = cache.get(key(1))

        cache.add(key(3), Picture())

        XCTAssertTrue(cache.contains(key(1)))
        XCTAssertFalse(cache.contains(key(2)))
        XCTAssertTrue(cache.contains(key(3)))
        XCTAssertEqual(cache.bytes, 20_000)
    }

    func test_lookingWithoutTouchingDoesNotSaveAPicture() {
        let cache = TileCache<Picture>(budget: 25_000)
        cache.add(key(1), Picture())
        cache.add(key(2), Picture())
        _ = cache.peek(key(1))

        cache.add(key(3), Picture())

        XCTAssertFalse(cache.contains(key(1)))
    }

    func test_thePictureJustAddedStaysEvenIfItAloneIsOverTheBudget() {
        let cache = TileCache<Picture>(budget: 5_000)

        cache.add(key(1), Picture())

        XCTAssertTrue(cache.contains(key(1)))
        cache.add(key(2), Picture())
        XCTAssertEqual((1...2).flatMap { cache.keys($0) }, [key(2)])
    }

    func test_addingTheSameKeyAgainReplacesItAndCountsItOnce() {
        let cache = TileCache<Picture>(budget: 1_000_000)

        cache.add(key(1), Picture())
        cache.add(key(1), Picture())

        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.bytes, 10_000)
    }

    func test_theKeysOfAPageAreListedAndRemovedTogether() {
        let cache = TileCache<Picture>(budget: 1_000_000)
        cache.add(key(1, 0), Picture())
        cache.add(key(1, 1), Picture())
        cache.add(key(2, 0), Picture())

        XCTAssertEqual(cache.keys(1).count, 2)

        cache.removeWhere(1) { $0.column == 1 }

        XCTAssertEqual(cache.keys(1), [key(1, 0)])
        XCTAssertEqual(cache.bytes, 20_000)
    }

    func test_clearingEmptiesIt() {
        let cache = TileCache<Picture>(budget: 1_000_000)
        cache.add(key(1), Picture())

        cache.clear()

        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.bytes, 0)
        XCTAssertTrue(cache.keys(1).isEmpty)
    }
}
