import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/ZoomMathTests.cs: the zoom limits, the steps and the zooms that fit a page to the window.

final class ZoomMathTests: XCTestCase {
    func test_fittingTheWidthFillsTheViewportLessTheMargins() {
        let zoom = ZoomMath.fitWidth(600, ViewSize(1000, 800))

        let shown = 600 * zoom * PageSpace.dipPerPoint
        XCTAssertEqual(shown, 1000 - 2 * ViewLayout.margin, accuracy: 1e-6)
    }

    func test_fittingThePageIsLimitedByTheTighterSide() {
        let tall = ViewSize(600, 3000)

        let zoom = ZoomMath.fitPage(tall, ViewSize(1000, 800))

        XCTAssertEqual(zoom, (800 - 2 * ViewLayout.margin) / 3000 / PageSpace.dipPerPoint, accuracy: 1e-6)
        XCTAssertLessThan(zoom, ZoomMath.fitWidth(600, ViewSize(1000, 800)))
    }

    func test_theStepsGoUpAndDownTheUsualScale() {
        XCTAssertEqual(ZoomMath.step(1, 1), 1.25)
        XCTAssertEqual(ZoomMath.step(1, -1), 0.75)
        XCTAssertEqual(ZoomMath.step(1.7, 1), 2)
        XCTAssertEqual(ZoomMath.step(1.7, -1), 1.5)
        XCTAssertEqual(ZoomMath.step(ZoomMath.maxZoom, 1), ZoomMath.maxZoom)
        XCTAssertEqual(ZoomMath.step(0.05, -1), 0.05)
    }

    func test_theLimitsLeaveRoomForAHugePage() {
        let (min, max) = ZoomMath.limits(14_400, 1)

        XCTAssertLessThan(min, 0.02)
        XCTAssertEqual(max, ZoomMath.maxZoom)
    }

    func test_aDenseScreenAndAHugePageLowerTheCeiling() {
        let (_, max) = ZoomMath.limits(200_000, 2)

        XCTAssertLessThan(max, ZoomMath.maxZoom)
        XCTAssertLessThanOrEqual(200_000 * max * PageSpace.dipPerPoint * 2, 4_000_001)
    }

    func test_aZoomIsHeldInsideTheLimits() {
        let limits = ZoomMath.limits(792, 1)

        XCTAssertEqual(ZoomMath.clamp(0.0001, limits), limits.min)
        XCTAssertEqual(ZoomMath.clamp(1000, limits), limits.max)
        XCTAssertEqual(ZoomMath.clamp(1, limits), 1)
    }
}
