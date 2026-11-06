import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/PageHistoryTests.cs: Back and Forward over the jumps a reader made.

final class PageHistoryTests: XCTestCase {
    func test_aNewHistoryGoesNowhere() {
        var history = PageHistory()

        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goBack(3))
        XCTAssertNil(history.goForward(3))
    }

    func test_backReturnsToThePageJumpedFromAndForwardComesAgain() {
        var history = PageHistory()
        history.jump(0, 10)

        XCTAssertEqual(history.goBack(10), 0)
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.goForward(0), 10)
        XCTAssertFalse(history.canGoForward)
    }

    func test_backWalksThroughSeveralJumpsInReverse() {
        var history = PageHistory()
        history.jump(0, 5)
        history.jump(5, 9)

        XCTAssertEqual(history.goBack(9), 5)
        XCTAssertEqual(history.goBack(5), 0)
        XCTAssertNil(history.goBack(0))
    }

    func test_aNewJumpAfterGoingBackForgetsTheForwardPages() {
        var history = PageHistory()
        history.jump(0, 5)
        _ = history.goBack(5)

        history.jump(0, 7)

        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(7), 0)
    }

    func test_aJumpToTheSamePageIsNotAJump() {
        var history = PageHistory()

        history.jump(4, 4)

        XCTAssertFalse(history.canGoBack)
    }

    func test_onlyTheLastHundredAreKept() {
        var history = PageHistory()
        for i in 0..<150 { history.jump(i, i + 1) }

        var count = 0
        var page = 150
        while let previous = history.goBack(page) {
            page = previous
            count += 1
        }

        XCTAssertEqual(count, 100)
    }

    func test_clearingForgetsEverything() {
        var history = PageHistory()
        history.jump(0, 5)

        history.clear()

        XCTAssertFalse(history.canGoBack)
    }
}
