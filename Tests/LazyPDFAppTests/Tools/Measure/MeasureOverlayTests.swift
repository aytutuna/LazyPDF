import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Follows MeasureOverlay.cs, which the Windows tests do not reach: what is drawn on the pages' overlay layers for the shape
// under way, for a finished measurement and for a snap point. The viewer is the real ViewerModel, so the page has a scale.

@MainActor
final class MeasureOverlayTests: XCTestCase {
    private func start(_ kind: MeasureKind) throws -> (tool: MeasureTool, overlay: MeasureOverlay, viewer: ViewerModel) {
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text(2)), renderer: FakeRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(tab)
        let tool = MeasureTool(viewer: viewer)
        tool.kind = kind
        return (tool, MeasureOverlay(viewer: viewer, tool: tool), viewer)
    }

    private func press(_ x: Double, _ y: Double) -> PagePointer {
        PagePointer(page: 0, point: ViewPoint(x, y), view: ViewPoint(x, y), pressed: true, clicks: 1)
    }

    private func ids(_ viewer: ViewerModel, page: Int = 0) -> [String] {
        viewer.overlay(page).items.map(\.id)
    }

    func test_theShapeUnderWayIsDrawnWithADotForEachCornerAndItsValue() throws {
        let (tool, overlay, viewer) = try start(.perimeter)
        tool.press(press(0, 0))
        tool.press(press(72, 0))

        overlay.draw([], .actual)

        let found = ids(viewer)
        XCTAssertEqual(found.filter { $0.contains(".dot.") }.count, 2)
        XCTAssertTrue(found.contains { $0.hasSuffix(".halo") })
        XCTAssertTrue(found.contains { $0.hasSuffix(".ink") })
        let label = try XCTUnwrap(viewer.overlay(0).items.first { $0.id.hasSuffix(".label") })
        guard case .text(let text) = label.shape else { return XCTFail("The label is not text.") }
        XCTAssertEqual(text.text, "25.4 mm")
    }

    func test_aFinishedMeasurementIsDrawnOnItsPageAndEverythingGoesOnClear() throws {
        let (_, overlay, viewer) = try start(.distance)
        let item = MeasureItem(.distance, 1, [ViewPoint(0, 0), ViewPoint(72, 0)])

        overlay.draw([item], .actual)

        XCTAssertFalse(ids(viewer, page: 1).isEmpty)
        XCTAssertTrue(ids(viewer, page: 0).isEmpty)
        overlay.clear()
        XCTAssertTrue(ids(viewer, page: 1).isEmpty)
    }

    func test_aSnapMarkShowsForAMouseHoverAndNotForAPressAlone() async throws {
        let (tool, overlay, viewer) = try start(.distance)
        tool.preload([0])
        await waitUntil { tool.snaps[0] != nil }
        let found = await viewer.text(0)
        let word = try XCTUnwrap(found?.words.first)
        let corner = viewer.geometry(0).toDisplay(word.bounds.left, word.bounds.top)

        tool.press(press(corner.x + 1, corner.y - 1))
        overlay.draw([], .actual)
        XCTAssertFalse(ids(viewer).contains { $0.hasSuffix("snap") })

        tool.move(PagePointer(page: 0, point: ViewPoint(corner.x + 1, corner.y - 1), view: ViewPoint(0, 0), pressed: false, clicks: 0))
        overlay.draw([], .actual)
        XCTAssertTrue(ids(viewer).contains("measure.snap"))

        tool.cancel()
        overlay.draw([], .actual)
        XCTAssertFalse(ids(viewer).contains("measure.snap"))
    }
}
