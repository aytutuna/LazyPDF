import XCTest
@testable import LazyPDFApp

final class PageSwipeTests: XCTestCase {
    func test_aLongLeftwardSwipeTurnsToTheNextPageOnce() {
        var swipe = PageSwipe()

        XCTAssertNil(swipe.add(dx: -50, dy: 0, began: true, ended: false))
        XCTAssertEqual(swipe.add(dx: -40, dy: 0, began: false, ended: false), 1)
        XCTAssertNil(swipe.add(dx: -100, dy: 0, began: false, ended: false))
    }

    func test_aRightwardSwipeTurnsBack() {
        var swipe = PageSwipe()

        XCTAssertEqual(swipe.add(dx: 80, dy: 0, began: true, ended: false), -1)
    }

    func test_aShortSwipeDoesNothing() {
        var swipe = PageSwipe()

        XCTAssertNil(swipe.add(dx: -79, dy: 0, began: true, ended: true))
    }

    func test_aMostlyVerticalSwipeNeverTurns() {
        var swipe = PageSwipe()

        XCTAssertNil(swipe.add(dx: -100, dy: 60, began: true, ended: false))
        XCTAssertNil(swipe.add(dx: -10, dy: 200, began: false, ended: false))
    }

    func test_aNewGestureStartsFromNothing() {
        var swipe = PageSwipe()
        XCTAssertNil(swipe.add(dx: -60, dy: 0, began: true, ended: false))

        XCTAssertNil(swipe.add(dx: -60, dy: 0, began: true, ended: false))
        XCTAssertEqual(swipe.add(dx: -30, dy: 0, began: false, ended: false), 1)
        XCTAssertEqual(swipe.add(dx: -80, dy: 0, began: true, ended: false), 1)
    }
}
