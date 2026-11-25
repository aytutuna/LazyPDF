import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/PageHistoryTests.cs: Back and Forward over the jumps a reader made.

final class PageHistoryTests: XCTestCase {
    private func at(_ page: Int, _ y: Double = 0) -> PagePoint { PagePoint(page, ViewPoint(0, y)) }

    func test_aNewHistoryGoesNowhere() {
        var history = PageHistory()

        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goBack(at(3)))
        XCTAssertNil(history.goForward(at(3)))
    }

    func test_backReturnsToThePlaceJumpedFromAndForwardComesAgain() {
        var history = PageHistory()
        history.jump(at(0, 300), at(10))

        XCTAssertEqual(history.goBack(at(10)), at(0, 300))
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.goForward(at(0, 300)), at(10))
        XCTAssertFalse(history.canGoForward)
    }

    func test_jumpSaysWhetherItMadeAnEntry() {
        var history = PageHistory()

        XCTAssertFalse(history.jump(at(2, 100), at(2, 120)))
        XCTAssertFalse(history.canGoBack)
        XCTAssertTrue(history.jump(at(2, 100), at(2, 400)))
        XCTAssertTrue(history.canGoBack)
    }

    func test_backWalksThroughSeveralJumpsInReverse() {
        var history = PageHistory()
        history.jump(at(0), at(5))
        history.jump(at(5), at(9))

        XCTAssertEqual(history.goBack(at(9)), at(5))
        XCTAssertEqual(history.goBack(at(5)), at(0))
        XCTAssertNil(history.goBack(at(0)))
    }

    func test_aNewJumpAfterGoingBackForgetsTheForwardPlaces() {
        var history = PageHistory()
        history.jump(at(0), at(5))
        _ = history.goBack(at(5))

        history.jump(at(0), at(7))

        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(at(7)), at(0))
    }

    func test_aJumpWithinFiftyPointsOfTheSamePageIsNotAJump() {
        var history = PageHistory()

        history.jump(at(4, 100), at(4, 149))
        XCTAssertFalse(history.canGoBack)

        history.jump(at(4, 100), at(4, 150))
        XCTAssertTrue(history.canGoBack)
    }

    func test_aFarJumpOnTheSamePageIsAJump() {
        var history = PageHistory()

        history.jump(at(4, 100), at(4, 400))

        XCTAssertEqual(history.goBack(at(4, 400)), at(4, 100))
    }

    func test_onlyTheLastHundredAreKept() {
        var history = PageHistory()
        for i in 0..<150 { history.jump(at(i), at(i + 1)) }

        var count = 0
        var place = at(150)
        while let previous = history.goBack(place) {
            place = previous
            count += 1
        }

        XCTAssertEqual(count, 100)
    }

    func test_clearingForgetsEverything() {
        var history = PageHistory()
        history.jump(at(0), at(5))

        history.clear()

        XCTAssertFalse(history.canGoBack)
    }
}
