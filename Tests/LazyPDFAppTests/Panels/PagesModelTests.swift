import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Pages panel; Windows has no test of PagesSidePanel or PageThumb, so these are the cases its code handles.

@MainActor
final class PagesModelTests: XCTestCase {
    private func attached(pages: Int = 3, renderer: DocumentRenderer = FakeRenderer(), labelled: Bool = false) throws
        -> (model: PagesModel, viewer: PanelViewer, tab: DocumentTab) {
        let tab = try PanelPdfs.tab(Pdfs.text(pages), renderer: renderer)
        if labelled { try PdfPageLabels.write(tab.document, [PageLabelRange(0, .lowerRoman)]) }
        let viewer = PanelViewer(tab)
        let model = PagesModel()
        model.attach(tab, viewer, RecordingHost())
        return (model, viewer, tab)
    }

    func test_everyPageGetsAThumbnailWithItsLabelAndASizeInTheBox() throws {
        let (model, _, _) = try attached(renderer: SizedRenderer(), labelled: true)

        XCTAssertEqual(model.thumbs.map { $0.label }, ["i", "ii", "iii"])
        XCTAssertEqual(model.thumbs[1].name, "Page ii")
        XCTAssertEqual(model.thumbs[0].width, 132)
        XCTAssertEqual(model.thumbs[0].height, 171)
        XCTAssertEqual(model.thumbs[1].width, 95)
        XCTAssertEqual(model.thumbs[1].height, 190)
    }

    func test_deletingAPageShortensTheListAndRenumbersIt() async throws {
        let (model, _, tab) = try attached(pages: 5, labelled: true)

        try PageOperations.delete(tab.document, [1])
        try tab.commit("Delete")

        await settle { model.thumbs.count == 4 }
        XCTAssertEqual(model.thumbs.map { $0.label }, ["i", "ii", "iii", "iv"])
    }

    func test_choosingAThumbnailGoesToThePageOnce() throws {
        let (model, viewer, _) = try attached()

        model.select(2)
        model.select(2)

        XCTAssertEqual(viewer.sent, [2])
    }

    func test_theCurrentPageFollowsTheViewer() throws {
        let (model, viewer, _) = try attached()

        viewer.pageIndex = 1
        XCTAssertEqual(model.current, 1)
        viewer.pageIndex = 9
        XCTAssertEqual(model.current, 2)
    }

    func test_theListIsBuiltAgainWhenTheFileChanges() async throws {
        let (model, _, tab) = try attached()
        let first = model.thumbs[0]

        try Pdfs.retitle(tab.session, "New title")
        try tab.commit("Properties")

        await settle { model.thumbs.first !== first }
        XCTAssertEqual(model.thumbs.count, 3)
        XCTAssertNotEqual(model.thumbs[0].id, first.id)
    }

    func test_aThumbnailIsDrawnAtTheDensityOfTheScreenAndLetGoOf() async throws {
        let (model, _, _) = try attached(renderer: DpiRenderer())
        model.setScale(3)
        let thumb = model.thumbs[0]

        thumb.load()
        await settle { thumb.image != nil }
        XCTAssertEqual(thumb.image?.width, 396)

        thumb.release()
        XCTAssertNil(thumb.image)
        thumb.load()
        await settle { thumb.image != nil }
    }

    func test_aPageThatCannotBeDrawnIsNotAskedForAgain() async throws {
        let renderer = DpiRenderer()
        renderer.draws = false
        let (model, _, _) = try attached(renderer: renderer)
        let thumb = model.thumbs[0]

        thumb.load()
        await settle { renderer.rendered.count == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        thumb.load()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(renderer.rendered.count, 1)
        XCTAssertNil(thumb.image)
    }

    func test_detachingEmptiesTheList() throws {
        let (model, _, _) = try attached()

        model.detach()

        XCTAssertTrue(model.thumbs.isEmpty)
        XCTAssertEqual(model.current, -1)
    }
}

/// Pages alternate between letter and a narrow page, as the panel viewer's do.
private final class SizedRenderer: DocumentRenderer {
    func load(_ session: PdfEditSession, _ password: String?) -> Bool { true }
    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { pageIndex % 2 == 0 ? (612, 792) : (300, 600) }
    func close() {}
    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { nil }
}
