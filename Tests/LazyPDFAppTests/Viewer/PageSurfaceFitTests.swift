import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/PageSurfaceFitTests.cs: the zoom that follows the window, for every document shown and in
// every layout, and where a destination lands.

final class PageSurfaceFitTests: XCTestCase {
    private func show(_ surface: OpenSurface, pages: Int, zoom: Double = 0, fit: FitMode = .none) throws {
        let session = try PdfEditSession.open(try TestPdfs.text(pages: pages))
        _ = surface.state.show(sizes: PageSurfaceState.pageSizes(session.document, nil), pageObjects: PageSurfaceState.pageObjects(session.document),
                               page: 0, zoom: zoom, fit: fit)
    }

    func test_aDocumentShownAfterTheFirstOpensFittedAtOnce() throws {
        let surface = try OpenSurface(pages: 2)

        try show(surface, pages: 3)

        XCTAssertEqual(surface.state.fit, .width)
        XCTAssertEqual(surface.state.zoom, ZoomMath.fitWidth(surface.state.pageSize(0).width, surfaceWindow), accuracy: 1e-3)
    }

    func test_aTabThatWasFittedStaysFittedWhenItComesBack() throws {
        let surface = try OpenSurface(pages: 2)
        _ = surface.state.setFit(.page)
        let remembered = (fit: surface.state.fit, zoom: 0.0)

        try show(surface, pages: 1)
        try show(surface, pages: 2, zoom: remembered.zoom, fit: remembered.fit)

        XCTAssertEqual(surface.state.fit, .page)
    }

    func test_twoPagesSideBySideFitTheWidthWithNoSideScroll() throws {
        let surface = try OpenSurface(pages: 4)

        _ = surface.state.setArrangement(columns: 2, cover: false, continuous: true)

        XCTAssertLessThanOrEqual(surface.state.extent.width, surfaceWindow.width + 0.5, "\(surface.state.extent.width) wide in \(surfaceWindow.width)")
    }

    func test_fitPageFollowsThePageOfAPagedLayoutThatIsTurnedTo() throws {
        let surface = try OpenSurface(pages: 3)
        _ = surface.state.setArrangement(columns: 1, cover: false, continuous: false)
        _ = surface.state.setFit(.page)
        let before = surface.state.zoom

        _ = surface.state.goToPage(2)

        XCTAssertEqual(surface.state.fit, .page)
        XCTAssertEqual(surface.state.zoom, before, accuracy: 1e-6)
    }

    func test_aDestinationInARotatedViewIsPlacedByBothOfItsCoordinates() throws {
        let surface = try OpenSurface(pages: 6)
        _ = surface.state.setZoom(1)
        _ = surface.state.setRotation(270)

        _ = surface.state.goToPage(3, at: ViewPoint(0, 100))
        let left = surface.state.viewRect.top
        _ = surface.state.goToPage(3, at: ViewPoint(300, 100))
        let right = surface.state.viewRect.top

        let rect = surface.state.layout.pageRect(3)
        XCTAssertNotEqual(left, right)
        XCTAssertGreaterThanOrEqual(left, rect.top - 1)
        XCTAssertLessThanOrEqual(left, rect.bottom)
    }

    func test_anUprightDestinationPutsItsHeightAtTheTopOfTheView() throws {
        let surface = try OpenSurface(pages: 6)
        _ = surface.state.setZoom(1)

        _ = surface.state.goToPage(2, at: ViewPoint(0, 150))

        let expected = surface.state.layout.pageRect(2).top + 150 * PageSpace.dipPerPoint
        XCTAssertEqual(surface.state.viewRect.top, expected, accuracy: 0.5)
    }
}
