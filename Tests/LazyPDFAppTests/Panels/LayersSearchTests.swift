import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// The Layers and Search panels, and the catalog of side panels (the side panel part of windows/LazyPDF.App.Tests/
// ToolCatalogTests.cs).

@MainActor
final class LayersModelTests: XCTestCase {
    private func attached() throws -> (model: LayersModel, viewer: PanelViewer) {
        let tab = try PanelPdfs.tab(PanelPdfs.full())
        let viewer = PanelViewer(tab)
        let model = LayersModel()
        model.attach(tab, viewer, RecordingHost())
        return (model, viewer)
    }

    func test_eachLayerIsARowWithItsBoxTicked() throws {
        let (model, _) = try attached()

        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.roots.map { $0.name }, ["Black box", "Notes"])
        XCTAssertTrue(model.roots.allSatisfy { $0.isOn })
        XCTAssertTrue(model.roots[0].canToggle)
        XCTAssertFalse(model.roots[1].canToggle)
    }

    func test_aFileWithoutLayersIsEmpty() throws {
        let tab = try PanelPdfs.tab(Pdfs.text())
        let model = LayersModel()
        model.attach(tab, PanelViewer(tab), RecordingHost())

        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(model.roots.isEmpty)
    }

    func test_tickingABoxChangesTheViewNotTheFile() throws {
        let (model, viewer) = try attached()
        let before = viewer.tab?.session.current

        model.toggle(model.roots[0], false)

        XCTAssertFalse(model.roots[0].isOn)
        XCTAssertEqual(viewer.layerCalls.count, 1)
        XCTAssertEqual(viewer.layerCalls[0].layer.number, 5)
        XCTAssertFalse(viewer.layerCalls[0].visible)
        XCTAssertEqual(viewer.tab?.session.current, before)
    }

    func test_aLockedLayerCannotBeToggled() throws {
        let (model, viewer) = try attached()

        model.toggle(model.roots[1], false)

        XCTAssertTrue(model.roots[1].isOn)
        XCTAssertTrue(viewer.layerCalls.isEmpty)
    }

    func test_theBoxesFollowAChangeTheViewMadeByItself() async throws {
        let (model, viewer) = try attached()

        viewer.viewChanged(PdfReference(5, 0), false)

        await settle { !model.roots[0].isOn }
        XCTAssertTrue(viewer.layerCalls.isEmpty)
        XCTAssertTrue(model.roots[1].isOn)
    }

    func test_theListFollowsTheViewerToTheLayersOfANewerFile() async throws {
        let (model, viewer) = try attached()
        let first = viewer.layers.layers[0]

        viewer.layers = LayerSet(layers: [first], order: [LayerNode(label: nil, layer: first, children: [])])

        await settle { model.roots.count == 1 }
        XCTAssertEqual(model.roots.map { $0.name }, ["Black box"])
    }
}

@MainActor
final class SearchModelTests: XCTestCase {
    private func attached(_ query: String, pages: Int = 3) async throws -> (model: SearchModel, viewer: PanelViewer) {
        let bytes = try TestPdfs.text(pages: pages, line: "The quick brown fox jumps over the lazy dog.")
        let tab = try PanelPdfs.tab(bytes)
        let viewer = PanelViewer(tab)
        viewer.search = ViewerSearch(source: { Task { await TextSource.open(bytes, password: nil) } }, startPage: { 0 })
        let model = SearchModel()
        model.attach(tab, viewer, RecordingHost())
        if !query.isEmpty { await viewer.search.start(query, TextSearchOptions()).value }
        return (model, viewer)
    }

    func test_beforeASearchThePanelSaysHowToStartOne() async throws {
        let (model, _) = try await attached("")

        XCTAssertEqual(model.summary, "Search the file to list every match here.")
        XCTAssertTrue(model.hits.isEmpty)
    }

    func test_everyHitIsListedAndTheSummaryCountsThem() async throws {
        let (model, _) = try await attached("lazy dog")

        XCTAssertEqual(model.hits.count, 3)
        XCTAssertEqual(model.summary, "3 results for lazy dog")
        XCTAssertEqual(model.current, 0)
    }

    func test_aSearchWithNoMatchSaysSo() async throws {
        let (model, _) = try await attached("zebra")

        XCTAssertEqual(model.summary, "No results for zebra")
    }

    func test_aPatternThatDoesNotParseSaysSo() async throws {
        let bytes = try TestPdfs.text()
        let tab = try PanelPdfs.tab(bytes)
        let viewer = PanelViewer(tab)
        viewer.search = ViewerSearch(source: { Task { await TextSource.open(bytes, password: nil) } }, startPage: { 0 })
        let model = SearchModel()
        model.attach(tab, viewer, RecordingHost())

        await viewer.search.start("(", TextSearchOptions(regex: true)).value

        XCTAssertEqual(model.summary, "Not a valid pattern")
    }

    func test_choosingAHitMovesTheSharedSearchToIt() async throws {
        let (model, viewer) = try await attached("lazy dog")

        model.select(2)

        XCTAssertEqual(viewer.search.current, 2)
        XCTAssertEqual(model.current, 2)
    }

    func test_choosingTheCurrentHitAgainStillTellsTheViewer() async throws {
        let (model, viewer) = try await attached("lazy dog")
        var moves = 0
        viewer.search.onCurrentChanged = { moves += 1 }

        model.select(model.current)

        XCTAssertEqual(moves, 1)
    }

    func test_theFindBarOpensFromThePanel() async throws {
        let (model, viewer) = try await attached("")

        model.showFind()

        XCTAssertEqual(viewer.findShown, 1)
    }
}

@MainActor
final class SidePanelCatalogTests: XCTestCase {
    func test_theRailHasTheSevenSidePanelsInTheOrderOfWindows() {
        XCTAssertEqual(ToolCatalog.sidePanels.map { $0.id }, ["pages", "bookmarks", "attachments", "layers", "comments", "signatures", "search"])
    }

    func test_aPanelIsFoundByItsId() {
        XCTAssertEqual(ToolCatalog.findSide("bookmarks")?.title, "Bookmarks")
        XCTAssertNil(ToolCatalog.findSide("nothing"))
        XCTAssertNil(SidePanelCatalog.create("nothing", TestFolders(root: TempDir(self).url)))
    }

    func test_everyPanelHasWordsASymbolAndAModel() throws {
        let folders = TestFolders(root: TempDir(self).url)
        for info in ToolCatalog.sidePanels {
            XCTAssertFalse(info.title.isEmpty)
            XCTAssertFalse(info.summary.isEmpty)
            XCTAssertFalse(info.symbol.isEmpty)
            XCTAssertNotNil(SidePanelCatalog.create(info.id, folders))
        }
    }

    func test_thePanelTheRailAlreadyRemembersIsInTheList() {
        let remembered = AppPreferences().sidePanel
        XCTAssertNotNil(ToolCatalog.findSide(remembered))
    }
}

@MainActor
final class SigningHostTests: XCTestCase {
    func test_openingTheSigningToolNamesTheFieldOnceForIt() {
        let fixture = ViewModelFixture(self)

        fixture.vm.openSigning("Approval")

        XCTAssertEqual(fixture.vm.activeToolId, "certificates")
        XCTAssertEqual(fixture.vm.takeSigningField(), "Approval")
        XCTAssertNil(fixture.vm.takeSigningField())
    }

    func test_theToolStaysOpenWhenAskedAgain() {
        let fixture = ViewModelFixture(self)

        fixture.vm.openSigning("A")
        fixture.vm.openSigning("B")

        XCTAssertEqual(fixture.vm.activeToolId, "certificates")
        XCTAssertEqual(fixture.vm.takeSigningField(), "B")
    }
}
