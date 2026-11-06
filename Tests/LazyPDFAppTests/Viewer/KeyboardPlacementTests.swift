import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors the placement arithmetic tested in windows/LazyPDF.App.Tests/KeyboardPlacementTests.cs: Enter starts in the middle of
// the page in view, the arrow keys move the mark, Enter again is a click there. The tests that drive the pointer tools through
// WPF key events (the signature box, crop and redact tools, the Escape and no-tool cases, a mouse click making no box) belong
// to the views and the tools, and are not ported here.

final class KeyboardPlacementTests: XCTestCase {
    func test_enterStartsInTheMiddleOfThePageInView() throws {
        let surface = try OpenSurface(pages: 2)
        let size = surface.state.pageSize(0)

        let placement = try XCTUnwrap(KeyPlacement(surface.state))

        XCTAssertEqual(placement.page, 0)
        XCTAssertTrue((0...size.width).contains(placement.point.x))
        XCTAssertTrue((0...size.height).contains(placement.point.y))
    }

    func test_theArrowKeysMoveTheClick() throws {
        let surface = try OpenSurface(pages: 2)
        var placement = try XCTUnwrap(KeyPlacement(surface.state))
        let middle = placement.point

        XCTAssertTrue(placement.move(.right, .normal, surface.state))
        XCTAssertTrue(placement.move(.right, .normal, surface.state))
        XCTAssertTrue(placement.move(.down, .normal, surface.state))

        XCTAssertGreaterThan(placement.point.x, middle.x)
        XCTAssertGreaterThan(placement.point.y, middle.y)
    }

    func test_theStepIsSmallWithShiftAndBigWithControl() throws {
        let surface = try OpenSurface(pages: 2)
        _ = surface.state.setZoom(1)
        var placement = try XCTUnwrap(KeyPlacement(surface.state))
        let start = placement.point.x

        _ = placement.move(.right, .small, surface.state)
        let small = placement.point.x - start
        _ = placement.move(.right, .big, surface.state)
        let big = placement.point.x - start - small

        XCTAssertEqual(small, 8 * 0.125 / PageSpace.dipPerPoint / surface.state.zoom, accuracy: 1e-6)
        XCTAssertEqual(big, 8 * 5 / PageSpace.dipPerPoint / surface.state.zoom, accuracy: 1e-6)
    }

    func test_theMarkIsKeptOnThePage() throws {
        let surface = try OpenSurface(pages: 1)
        var placement = try XCTUnwrap(KeyPlacement(surface.state))

        for _ in 0..<200 { _ = placement.move(.left, .big, surface.state) }
        for _ in 0..<200 { _ = placement.move(.up, .big, surface.state) }

        XCTAssertEqual(placement.point, ViewPoint(0, 0))
    }

    func test_aMovingMarkMeansNothingOnceItsPageIsNotLaidOut() throws {
        let surface = try OpenSurface(pages: 3)
        _ = surface.state.setArrangement(columns: 1, cover: false, continuous: false)
        var placement = try XCTUnwrap(KeyPlacement(surface.state))
        _ = surface.state.goToPage(2)

        XCTAssertFalse(placement.move(.right, .normal, surface.state))
    }

    func test_nothingStartsWhenNoPageIsInView() {
        XCTAssertNil(KeyPlacement(PageSurfaceState()))
    }
}
