import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/HomeTilesTests.cs, the state part. The keyboard and placement parts are views.

@MainActor
final class HomeTilesTests: XCTestCase {
    private let ids = ["open", "create", "combine", "compress", "protect", "sign", "form", "edit", "export", "batch"]

    func test_theTilesAreTheTenJobsInOrder() {
        let f = ViewModelFixture(self)

        XCTAssertEqual(f.vm.tiles.map(\.id), ids)
        XCTAssertEqual(f.vm.tiles.map(\.title),
                       ["Open", "Create", "Combine", "Make smaller", "Protect", "Sign", "Fill a form", "Edit", "Export", "Batch"])
    }

    func test_withNoFileOnlyOpenIsAvailableAndTheOthersSayWhy() {
        let f = ViewModelFixture(self)

        for tile in f.vm.tiles where !["open", "create", "batch"].contains(tile.id) {
            XCTAssertFalse(tile.available, tile.id)
            XCTAssertEqual(tile.reason, "Open a file first", tile.id)
        }
        XCTAssertTrue(f.vm.tiles[0].available)
        XCTAssertNil(f.vm.tiles[0].reason)
    }

    func test_batchNeedsNoFile() {
        let f = ViewModelFixture(self)
        let batch = f.vm.tiles.first { $0.id == AppViewModel.batchTile }

        XCTAssertEqual(batch?.available, true)
        XCTAssertNil(batch?.reason)
    }

    func test_aTileThatCannotStartTellsScreenReadersWhy() {
        let f = ViewModelFixture(self)

        XCTAssertEqual(f.vm.tiles.first { $0.id == "combine" }?.helpText,
                       "Join files into a new one, or split this one. Not available: Open a file first")
        XCTAssertEqual(f.vm.tiles[0].helpText, "Open a PDF, a picture or a text file.")
    }

    func test_scanIsOnlyThereWhenLazyScanIs() {
        let f = ViewModelFixture(self)
        XCTAssertFalse(f.vm.tiles.contains { $0.id == "scan" })

        f.sisters.lazyScanInstalled = true
        let tiles = f.vm.tiles
        let at = tiles.firstIndex { $0.id == "scan" }!
        XCTAssertTrue(tiles[at].available)
        XCTAssertNil(tiles[at].reason)
        XCTAssertEqual(tiles[at + 1].id, "export")
    }

    func test_onceAFileIsOpenTheToolTilesAreAvailable() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        f.vm.select(HomeTab.shared)

        for tile in f.vm.tiles where tile.id != "scan" {
            XCTAssertTrue(tile.available, tile.id)
            XCTAssertNil(tile.reason, tile.id)
        }
    }

    func test_aTileOpensItsToolOnTheDocumentLastInUse() async {
        for (tile, tool) in [("combine", "combine"), ("compress", "optimize"), ("protect", "protect"), ("sign", "fillsign"),
                             ("form", "forms"), ("edit", "editcontent"), ("export", "export")] {
            let f = ViewModelFixture(self)
            await f.vm.open([f.pdf("a.pdf"), f.pdf("b.pdf")])
            f.vm.select(HomeTab.shared)

            f.vm.startTile(tile)

            XCTAssertEqual(f.vm.activeToolId, tool, tile)
            XCTAssertEqual(f.vm.activeDocument?.title, "b.pdf", tile)
        }
    }

    func test_aTileThatCannotStartDoesNothing() {
        let f = ViewModelFixture(self)

        f.vm.startTile("combine")

        XCTAssertNil(f.vm.activeToolId)
        XCTAssertTrue(f.vm.isHome)
    }

    func test_scanStartsLazyScanOnlyWhenItIsThere() {
        let f = ViewModelFixture(self)

        f.vm.startTile("scan")
        XCTAssertEqual(f.sisters.scanOpened, 0)

        f.sisters.lazyScanInstalled = true
        f.vm.startTile("scan")
        XCTAssertEqual(f.sisters.scanOpened, 1)
    }

    func test_aToolTileWithoutAFileSaysToOpenOne() {
        let f = ViewModelFixture(self)

        f.vm.startTile("combine")

        XCTAssertTrue(f.vm.statusFull.contains("Open a file first"))
    }

    func test_afterTheLastDocumentClosesTheTilesWaitForAFileAgain() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        f.vm.close(f.vm.activeDocument!)

        XCTAssertEqual(f.vm.tiles.first { $0.id == "combine" }?.available, false)
    }

    func test_thePanelAndTheAppearanceAreRememberedForTheNextStart() {
        let f = ViewModelFixture(self)

        f.vm.setSidePanel("layers")
        f.vm.setAppearance(.dark)
        let next = f.makeViewModel()

        XCTAssertEqual(next.sidePanelId, "layers")
        XCTAssertEqual(next.appearance, .dark)
        f.vm.setSidePanel("layers")
        XCTAssertEqual(f.vm.sidePanelId, "")
        f.vm.toggleSidePanel()
        XCTAssertEqual(f.vm.sidePanelId, "layers")
    }
}
