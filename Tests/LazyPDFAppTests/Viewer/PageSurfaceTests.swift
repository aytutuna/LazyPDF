import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors the parts of windows/LazyPDF.App.Tests/PageSurfaceTests.cs that do not need WPF: the scrolling pages without a window,
// zoom around a point, going to a page, the layouts, and a reload that keeps the place. The overlay test (an overlay element is
// kept for the page and attached only while it is near) belongs to the drawing surface and is not ported.

let surfaceWindow = ViewSize(800, 600)

/// A document shown in a surface the size of `surfaceWindow`, as PageSurface.Show then Measure leave it.
final class OpenSurface {
    let session: PdfEditSession
    var state = PageSurfaceState()
    private var bytes: [UInt8]

    init(pages: Int) throws {
        session = try PdfEditSession.open(try TestPdfs.text(pages: pages))
        bytes = session.current
        _ = state.show(sizes: PageSurfaceState.pageSizes(session.document, nil), pageObjects: PageSurfaceState.pageObjects(session.document),
                       page: 0, zoom: 0, fit: .none)
        _ = state.setViewport(surfaceWindow)
    }

    /// What PageSurface.Reload does after the tab committed a change.
    @discardableResult
    func reload() -> SurfaceChange {
        let document = session.document
        let changed = RevisionDiff.changed(bytes, session.current)
        bytes = session.current
        return state.reload(sizes: PageSurfaceState.pageSizes(document, nil), pageObjects: PageSurfaceState.pageObjects(document), changed: changed) {
            RevisionDiff.touches(document, document.pages[$0], changed!)
        }
    }
}

final class PageSurfaceTests: XCTestCase {
    func test_aZeroPixelDensityIsIgnored() throws {
        let surface = try OpenSurface(pages: 3)
        _ = surface.state.scrollBy(0, 50)

        _ = surface.state.setPixelsPerDip(0)
        _ = surface.state.scrollBy(0, 10)

        XCTAssertTrue(surface.state.offsetY.isFinite)
        XCTAssertTrue(surface.state.offsetX.isFinite)
        XCTAssertFalse(surface.state.viewRect.isEmpty)
    }

    func test_anEmptyRectHasNoRightOrBottom() {
        XCTAssertEqual(ViewRect.empty.right, -.infinity)
        XCTAssertEqual(ViewRect.empty.bottom, -.infinity)
    }

    func test_aFileOpensFittedToTheWidth() throws {
        let surface = try OpenSurface(pages: 3)

        let expected = ZoomMath.fitWidth(surface.state.pageSize(0).width, surfaceWindow)
        XCTAssertEqual(surface.state.fit, .width)
        XCTAssertEqual(surface.state.zoom, expected, accuracy: 1e-6)
        XCTAssertEqual(surface.state.pageCount, 3)
        XCTAssertEqual(surface.state.currentPage, 0)
    }

    func test_theTabRemembersTheZoomAndThePage() throws {
        let surface = try OpenSurface(pages: 5)

        _ = surface.state.goToPage(3)
        _ = surface.state.setZoom(1.5)

        XCTAssertEqual(surface.state.currentPage, 3)
        XCTAssertEqual(surface.state.zoom, 1.5)
        XCTAssertEqual(surface.state.fit, .none)
    }

    func test_goingToAPageScrollsItsTopIntoView() throws {
        let surface = try OpenSurface(pages: 5)

        _ = surface.state.goToPage(3)

        XCTAssertEqual(surface.state.currentPage, 3)
        XCTAssertEqual(surface.state.offsetY, surface.state.layout.pageRect(3).top - ViewLayout.margin, accuracy: 0.5)
    }

    func test_theTopPlaceIsWhereTheTopOfTheSurfaceIsOnThePage() throws {
        let surface = try OpenSurface(pages: 5)
        _ = surface.state.goToPage(2)
        _ = surface.state.scrollBy(0, 200)

        let place = try XCTUnwrap(surface.state.topPlace())

        XCTAssertEqual(place.page, 2)
        XCTAssertEqual(place.point.y, 200 + ViewLayout.margin, accuracy: 1.5)
    }

    func test_theTopPlaceMayLieAboveItsPage() throws {
        let surface = try OpenSurface(pages: 5)
        _ = surface.state.goToPage(2)
        _ = surface.state.scrollBy(0, -ViewLayout.margin + 0.5)

        let place = try XCTUnwrap(surface.state.topPlace())

        XCTAssertEqual(place.page, 2)
        XCTAssertLessThan(place.point.y, 0)
    }

    func test_theTopPlaceOfOnePageAtATimeIsOnThatPage() throws {
        let surface = try OpenSurface(pages: 5)
        _ = surface.state.setArrangement(columns: 1, cover: false, continuous: false)
        _ = surface.state.goToPage(3)

        let place = try XCTUnwrap(surface.state.topPlace())

        XCTAssertEqual(place.page, 3)
    }

    func test_scrollingByHandChangesThePageInView() throws {
        let surface = try OpenSurface(pages: 5)
        var raised = 0

        if surface.state.goToPage(1).contains(.page) { raised += 1 }
        let layout = surface.state.layout
        if surface.state.scrollBy(0, layout.pageRect(2).top - surface.state.offsetY - 50).contains(.page) { raised += 1 }

        XCTAssertEqual(surface.state.currentPage, 2)
        XCTAssertGreaterThanOrEqual(raised, 2)
    }

    func test_zoomingKeepsThePointUnderThePointerWhereItWas() throws {
        let surface = try OpenSurface(pages: 4)
        _ = surface.state.goToPage(1)
        let pointer = ViewPoint(420, 300)
        let found = try XCTUnwrap(surface.state.hit(pointer, nearest: true))

        _ = surface.state.setZoom(surface.state.zoom * 2, around: pointer)

        let after = try XCTUnwrap(surface.state.pageMatrix(found.page)).transform(found.point)
        XCTAssertEqual(after.x, pointer.x, accuracy: 0.5)
        XCTAssertEqual(after.y, pointer.y, accuracy: 0.5)
    }

    func test_theZoomStaysBetweenTheLimits() throws {
        let surface = try OpenSurface(pages: 1)
        let (min, max) = surface.state.zoomLimits

        _ = surface.state.setZoom(1000)
        XCTAssertEqual(surface.state.zoom, max)
        _ = surface.state.setZoom(0.0001)
        XCTAssertEqual(surface.state.zoom, min)
    }

    func test_aPointOnARotatedPageComesBackAsThePageSpaceItWas() throws {
        for rotation in [0, 90, 180, 270] {
            let surface = try OpenSurface(pages: 2)
            _ = surface.state.setRotation(rotation)
            _ = surface.state.setZoom(1)
            let size = surface.state.pageSize(0)
            let spot = ViewPoint(size.width * 0.25, size.height * 0.75)

            let onScreen = try XCTUnwrap(surface.state.pageMatrix(0)).transform(spot)
            let hit = try XCTUnwrap(surface.state.hit(onScreen))

            XCTAssertEqual(hit.page, 0)
            XCTAssertEqual(hit.point.x, spot.x, accuracy: 1e-3)
            XCTAssertEqual(hit.point.y, spot.y, accuracy: 1e-3)
        }
    }

    func test_aRotationSwapsTheShapeOfThePageOnTheScreen() throws {
        let surface = try OpenSurface(pages: 1)
        _ = surface.state.setZoom(1)
        let upright = surface.state.layout.pageRect(0).size

        _ = surface.state.setRotation(90)

        let turned = surface.state.layout.pageRect(0).size
        XCTAssertEqual(turned.height, upright.width, accuracy: 0.5)
        XCTAssertEqual(turned.width, upright.height, accuracy: 0.5)
        XCTAssertEqual(surface.state.rotation, 90)
    }

    func test_onePageAtATimeLaysOutOnlyThatPageAndTurnsItAtTheEdge() throws {
        let surface = try OpenSurface(pages: 5)
        _ = surface.state.setArrangement(columns: 1, cover: false, continuous: false)

        _ = surface.state.goToPage(2)
        XCTAssertTrue(surface.state.layout.contains(2))
        XCTAssertFalse(surface.state.layout.contains(1))

        _ = surface.state.setZoom(2)
        _ = surface.state.scrollBy(0, 1_000_000)
        _ = surface.state.scrollBy(0, 100)

        XCTAssertEqual(surface.state.currentPage, 3)
        XCTAssertTrue(surface.state.layout.contains(3))
        XCTAssertEqual(surface.state.offsetY, 0)
    }

    func test_facingPagesWithACoverGoByTheirSpreads() throws {
        let surface = try OpenSurface(pages: 6)
        _ = surface.state.setArrangement(columns: 2, cover: true, continuous: true)

        _ = surface.state.goToPage(2)

        let layout = surface.state.layout
        XCTAssertEqual(surface.state.currentPage, 2)
        XCTAssertEqual(layout.pageRect(1).top, layout.pageRect(2).top)
        XCTAssertLessThan(layout.pageRect(0).bottom, layout.pageRect(1).top)
    }

    func test_aReloadKeepsTheScrollPositionOnWhatWasInView() throws {
        let surface = try OpenSurface(pages: 6)
        _ = surface.state.setZoom(1)
        _ = surface.state.goToPage(3)
        _ = surface.state.scrollBy(0, 120)
        let offset = surface.state.offsetY

        try TestPdfs.retitle(surface.session, "Edited")
        _ = try surface.session.commit("Title")
        surface.reload()

        XCTAssertEqual(surface.state.currentPage, 3)
        XCTAssertEqual(surface.state.offsetY, offset, accuracy: 0.5)
    }

    func test_aReloadGivesNewPicturesOnlyToThePagesTheEditTouched() throws {
        let surface = try OpenSurface(pages: 4)
        _ = surface.state.setZoom(0.1)
        let before = surface.state.versions

        try TestPdfs.addNote(surface.session, page: 1)
        _ = try surface.session.commit("Note")
        surface.reload()

        let after = surface.state.versions
        XCTAssertEqual(before[0], after[0])
        XCTAssertNotEqual(before[1], after[1])
        XCTAssertEqual(before[2], after[2])
        XCTAssertEqual(before[3], after[3])
    }

    func test_aReloadAfterAFileRewriteGivesEveryPageNewPictures() throws {
        let surface = try OpenSurface(pages: 3)
        _ = surface.state.setZoom(0.1)
        let before = surface.state.versions

        try surface.session.saveCompact(temporaryFile("compact.pdf", for: self))
        surface.reload()

        for page in 0..<3 { XCTAssertNotEqual(before[page], surface.state.versions[page]) }
    }

    func test_aReloadAfterPagesWereDeletedStaysInsideTheFile() throws {
        let surface = try OpenSurface(pages: 5)
        _ = surface.state.goToPage(4)

        try PageOperations.delete(surface.session.document, [3, 4])
        _ = try surface.session.commit("Delete pages")
        surface.reload()

        XCTAssertEqual(surface.state.pageCount, 3)
        XCTAssertTrue((0...2).contains(surface.state.currentPage))
    }

    func test_aFileTheSystemCannotDrawStillHasItsPagesLaidOut() throws {
        let session = try PdfEditSession.open(try TestPdfs.text(pages: 3))
        let renderer = NoSizeRenderer()
        var state = PageSurfaceState()

        _ = state.show(sizes: PageSurfaceState.pageSizes(session.document, renderer), pageObjects: PageSurfaceState.pageObjects(session.document),
                       page: 0, zoom: 0, fit: .none)
        _ = state.setViewport(surfaceWindow)

        XCTAssertEqual(state.pageCount, 3)
        XCTAssertGreaterThan(state.pageSize(0).width, 100)
        XCTAssertTrue(state.layout.contains(0))
    }

    func test_betweenPagesThereIsNoHitUnlessTheNearestIsAsked() throws {
        let surface = try OpenSurface(pages: 3)
        _ = surface.state.setZoom(1)
        let rect = surface.state.layout.pageRect(0)
        let gap = ViewPoint(rect.left + 10, rect.bottom + 2 - surface.state.offsetY)

        XCTAssertNil(surface.state.hit(gap))
        XCTAssertEqual(surface.state.hit(gap, nearest: true)?.page, 0)
    }

    func test_theTilesWantedAreThePreviewsOfWhatIsInViewFirst() throws {
        let surface = try OpenSurface(pages: 8)
        _ = surface.state.setZoom(1)

        let wanted = surface.state.wantedTiles(settling: false, isKnown: { _ in false }, reachable: { $0 })

        XCTAssertFalse(wanted.isEmpty)
        XCTAssertLessThanOrEqual(wanted.count, 96)
        let first = try XCTUnwrap(wanted.min { $0.priority < $1.priority })
        XCTAssertTrue(first.spec.key.isPreview)
        XCTAssertEqual(first.spec.key.page, 0)
        XCTAssertTrue(wanted.allSatisfy { $0.spec.key.page < 8 })

        let settled = surface.state.wantedTiles(settling: true, isKnown: { _ in false }, reachable: { $0 })
        XCTAssertTrue(settled.allSatisfy { $0.spec.key.isPreview })
        let known = surface.state.wantedTiles(settling: false, isKnown: { _ in true }, reachable: { $0 })
        XCTAssertTrue(known.isEmpty)
    }
}

/// A renderer that draws nothing and has no sizes, like a system that cannot read the file.
final class NoSizeRenderer: DocumentRenderer {
    func load(_ session: PdfEditSession, _ password: String?) -> Bool { false }
    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (0, 0) }
    func close() {}
    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { nil }
}
