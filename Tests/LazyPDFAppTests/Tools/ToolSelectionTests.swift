import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/ToolSelectionTests.cs and the state half of HomeKeyboardTests.cs: the tool and the side
// panel in use, the busy bar and the info bar. The appearance, the remembered panel and a cancelled job are covered in
// HomeTilesTests and BusyCloseTests.
//
// Not ported: the focus and accessibility checks of HomeKeyboardTests (a WPF Button's Focusable and HelpText); the
// SwiftUI tile is a Button with an accessibility hint, drawn by the UI tests.

@MainActor
final class ToolSelectionTests: XCTestCase {
    func test_pickingAToolSelectsItAndPickingItAgainClosesIt() async {
        let f = ViewModelFixture(self)

        f.vm.selectTool("stamps")
        XCTAssertEqual(f.vm.activeToolId, "stamps")
        XCTAssertEqual(f.vm.activeTool?.group, .edit)

        f.vm.selectTool("stamps")
        XCTAssertNil(f.vm.activeToolId)
    }

    func test_anotherToolReplacesTheFirst() async {
        let f = ViewModelFixture(self)
        f.vm.selectTool("stamps")

        f.vm.selectTool("redact")

        XCTAssertEqual(f.vm.activeToolId, "redact")
    }

    func test_anUnknownToolIsIgnored() async {
        let f = ViewModelFixture(self)
        f.vm.selectTool("stamps")

        f.vm.selectTool("nothing")

        XCTAssertEqual(f.vm.activeToolId, "stamps")
    }

    func test_pickingTheOpenPanelCollapsesTheRailAndTheToggleBringsItBack() async {
        let f = ViewModelFixture(self)
        f.vm.setSidePanel("pages")
        XCTAssertEqual(f.vm.sidePanelId, "")
        XCTAssertNil(f.vm.sidePanel)

        f.vm.toggleSidePanel()
        XCTAssertEqual(f.vm.sidePanelId, "pages")
        XCTAssertEqual(f.vm.sidePanel?.title, "Pages")

        f.vm.setSidePanel("search")
        f.vm.toggleSidePanel()
        XCTAssertEqual(f.vm.sidePanelId, "")
        f.vm.toggleSidePanel()
        XCTAssertEqual(f.vm.sidePanelId, "search")
    }

    func test_theBusyBarClearsWhenTheWorkFails() async {
        let f = ViewModelFixture(self)

        do {
            try await f.vm.runBusy("Working") { _ in throw InvalidOperationException("no") }
            XCTFail("the error should come out")
        } catch {}

        XCTAssertFalse(f.vm.isBusy)
    }

    func test_theStatusLineIsShortAndTheSentenceIsKept() async {
        let f = ViewModelFixture(self)

        f.vm.setStatus("Saved report.pdf. The old version is in the file's history.")

        XCTAssertEqual(f.vm.statusShort, "Saved report.pdf")
        XCTAssertEqual(f.vm.statusFull, "Saved report.pdf. The old version is in the file's history.")
    }

    func test_theInfoBarShowsAProblemAndIsDismissed() async {
        let f = ViewModelFixture(self)

        f.vm.showProblem(Problem("Not saved", "Check the disk."))
        XCTAssertEqual(f.vm.message?.isError, true)

        f.vm.showNotice("File changed", "By another program.", NoticeAction("Reload") {})
        XCTAssertEqual(f.vm.message?.isError, false)
        XCTAssertEqual(f.vm.message?.action?.text, "Reload")

        f.vm.dismissMessage()
        XCTAssertNil(f.vm.message)
    }

    func test_clickingATileThatCannotStartIsStillReported() async {
        let f = ViewModelFixture(self)

        f.vm.startTile("combine")
        f.vm.startTile("batch")

        XCTAssertTrue(f.vm.statusFull.contains("Not available: Open a file first"))
        XCTAssertNil(f.vm.activeToolId)
    }
}
