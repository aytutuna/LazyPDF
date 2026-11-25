#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// The inspector content of a tool (windows/LazyPDF.App/MainWindow.Tools.cs, Place and RefreshAction): the panel is attached to
// the document while shown and detached when it goes, the pointer goes back to the viewer, and a tool nobody has ported shows
// what it is for. Windows tests this through the main window; the window is not under test here, so ToolPanels is.

@MainActor
private final class RecordingTool: PagePointerTool {
    var cursor: PointerCursor? { nil }
    var cancelled = 0

    func press(_ pointer: PagePointer) {}
    func move(_ pointer: PagePointer) {}
    func release(_ pointer: PagePointer) {}
    func cancel() { cancelled += 1 }
}

@MainActor
private final class FakeModel: ToolPanelModel {
    var attached: DocumentTab?
    var attachCount = 0
    var detachCount = 0
    var takesPointer = false
    var handsIn = true
    var enabled = true
    let tool = RecordingTool()

    var action: ToolAction? {
        ToolAction("Run it", symbol: "play", canRun: { [self] in enabled }, run: {})
    }

    func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        attached = tab
        attachCount += 1
        if takesPointer { viewer.pointerTool = tool }
    }

    func detach() {
        attached = nil
        detachCount += 1
    }

    func handIn() -> Bool { handsIn }
}

@MainActor
final class ToolHostTests: XCTestCase {
    private func panels(_ rig: ToolViewRig) -> ToolPanels {
        ToolPanels(host: rig.host, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
    }

    private func panel(_ model: FakeModel) -> ToolPanel {
        ToolPanel(model) { _ in Text("panel") }
    }

    func test_aPanelIsAttachedToTheDocumentWhileItIsShownAndDetachedWhenItLeaves() throws {
        let rig = try ToolViewRig()
        let panels = panels(rig)
        let model = FakeModel()
        let shown = panel(model)

        panels.show(shown, id: "stamps", tab: rig.tab, viewer: rig.viewer)
        XCTAssertTrue(model.attached === rig.tab)

        panels.leave(shown)
        XCTAssertNil(model.attached)
        XCTAssertEqual(model.detachCount, 1)
    }

    func test_aToolThatTookThePointerGivesItBackWhenItLeaves() throws {
        let rig = try ToolViewRig()
        let panels = panels(rig)
        let model = FakeModel()
        model.takesPointer = true
        let shown = panel(model)

        panels.show(shown, id: "measure", tab: rig.tab, viewer: rig.viewer)
        XCTAssertNotNil(rig.viewer.pointerTool)

        panels.leave(shown)
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_showingAnotherPanelDetachesTheFirstWhicheverViewGoesFirst() throws {
        let rig = try ToolViewRig()
        let panels = panels(rig)
        let first = FakeModel()
        let second = FakeModel()
        let one = panel(first), two = panel(second)
        panels.show(one, id: "stamps", tab: rig.tab, viewer: rig.viewer)

        panels.show(two, id: "redact", tab: rig.tab, viewer: rig.viewer)
        // The view of the first tool goes after the second came: it must not take the second's panel down.
        panels.leave(one)

        XCTAssertEqual(first.detachCount, 1)
        XCTAssertNil(first.attached)
        XCTAssertTrue(second.attached === rig.tab)
        XCTAssertEqual(second.detachCount, 0)
    }

    func test_aPanelShownForAnotherDocumentIsAttachedAfreshAndThePointerIsNotKept() throws {
        let rig = try ToolViewRig()
        let other = try ToolViewRig()
        let panels = panels(rig)
        let model = FakeModel()
        model.takesPointer = true
        let shown = panel(model)

        panels.show(shown, id: "measure", tab: rig.tab, viewer: rig.viewer)
        panels.show(shown, id: "measure", tab: other.tab, viewer: other.viewer)

        XCTAssertNil(rig.viewer.pointerTool)
        XCTAssertTrue(model.attached === other.tab)
        XCTAssertEqual(model.attachCount, 2)
        XCTAssertEqual(model.detachCount, 1)
    }

    func test_theButtonIsTheOneOfTheToolShown() throws {
        let rig = try ToolViewRig()
        let panels = panels(rig)
        let model = FakeModel()
        let shown = panel(model)
        XCTAssertNil(panels.action(for: "stamps"))

        panels.show(shown, id: "stamps", tab: rig.tab, viewer: rig.viewer)

        XCTAssertEqual(panels.action(for: "stamps")?.text, "Run it")
        XCTAssertNil(panels.action(for: "redact"))
        model.enabled = false
        XCTAssertEqual(panels.action(for: "stamps")?.canRun(), false)

        panels.leave(shown)
        XCTAssertNil(panels.action(for: "stamps"))
    }

    func test_theWindowAsksTheShownPanelToHandInWhatIsTyped() throws {
        let rig = try ToolViewRig()
        let panels = panels(rig)
        let model = FakeModel()
        model.handsIn = false
        XCTAssertTrue(panels.handIn())

        panels.show(panel(model), id: "stamps", tab: rig.tab, viewer: rig.viewer)

        XCTAssertFalse(panels.handIn())
    }

    func test_theRegistryHasThePropertiesAndCleanForSharingPanelsAndNothingForAnUnknownId() throws {
        let context = { (id: String) in ToolContext(info: ToolCatalog.find(id)!, folders: StandInFolders(root: FileManager.default.temporaryDirectory)) }

        XCTAssertTrue(ToolRegistry.panel(for: "metadata", context("metadata"))?.model is MetadataModel)
        XCTAssertTrue(ToolRegistry.panel(for: "sanitize", context("sanitize"))?.model is SanitizeModel)
        XCTAssertNil(ToolRegistry.panel(for: "nothing", context("metadata")))
    }

    func test_theHostMakesAPanelOnlyForAToolTheCatalogKnows() throws {
        let rig = try ToolViewRig()
        let panels = panels(rig)

        XCTAssertNotNil(panels.panel("metadata"))
        XCTAssertNil(panels.panel("nothing"))
    }

    func test_typedPropertiesComeBackWhenThePanelIsShownAgain() throws {
        let rig = try ToolViewRig()
        let panels = panels(rig)
        let first = try XCTUnwrap(panels.panel("metadata"))
        panels.show(first, id: "metadata", tab: rig.tab, viewer: rig.viewer)
        let typed = try XCTUnwrap(first.model as? MetadataModel)
        typed.hideToolbar = true
        panels.leave(first)

        let again = try XCTUnwrap(panels.panel("metadata"))
        panels.show(again, id: "metadata", tab: rig.tab, viewer: rig.viewer)

        XCTAssertTrue(again.model === first.model)
        XCTAssertTrue(typed.hideToolbar)
    }

    func test_eachToolHasItsOwnPanel() throws {
        let rig = try ToolViewRig()
        let panels = panels(rig)

        XCTAssertFalse(try XCTUnwrap(panels.panel("metadata")).model === (try XCTUnwrap(panels.panel("sanitize"))).model)
    }

    func test_theViewerShowsTheDocumentBeforeThePanelAttaches() throws {
        let rig = try ToolViewRig()
        let viewer = PanelViewer()
        let panels = panels(rig)
        let model = FakeModel()

        panels.show(panel(model), id: "stamps", tab: rig.tab, viewer: viewer)

        XCTAssertTrue(viewer.tab === rig.tab)
        XCTAssertEqual(viewer.shows, 1)
        XCTAssertTrue(model.attached === rig.tab)
    }

    func test_aViewerAlreadyShowingTheDocumentIsNotShownAgain() throws {
        let rig = try ToolViewRig()
        let panels = panels(rig)

        panels.show(panel(FakeModel()), id: "stamps", tab: rig.tab, viewer: rig.viewer)

        XCTAssertEqual(rig.viewer.shows, 0)
    }

    func test_leavingEndsTheToolsMarksAndItsOpenFieldsButNotAnotherToolsOnes() throws {
        let rig = try ToolViewRig()
        let panels = panels(rig)
        let shown = panel(FakeModel())
        panels.show(shown, id: "stamps", tab: rig.tab, viewer: rig.viewer)
        let layer = rig.viewer.overlay(0)
        layer.set(OverlayItem("stamps.preview", .rect(ViewRect(0, 0, 10, 10))))
        layer.set(OverlayItem("measure.line", .rect(ViewRect(0, 0, 10, 10))))
        var heard: [String?] = []
        layer.open(OverlayField("stamps.text", area: ViewRect(0, 0, 10, 10), text: "typed") { heard.append($0) })

        panels.leave(shown)

        XCTAssertEqual(layer.items.map(\.id), ["measure.line"])
        XCTAssertTrue(layer.fields.isEmpty)
        XCTAssertEqual(heard, ["typed"])
    }

    func test_leavingGivesTheStageBackAndTheStageViewIsTheShownPanels() throws {
        let rig = try ToolViewRig()
        let panels = panels(rig)
        let model = FakeModel()
        let shown = ToolPanel(model, stage: { _ in Text("stage") }) { _ in Text("panel") }
        XCTAssertNil(panels.stage)

        panels.show(shown, id: "pages", tab: rig.tab, viewer: rig.viewer)
        XCTAssertNotNil(panels.stage)

        panels.leave(shown)
        XCTAssertNil(panels.stage)
        XCTAssertEqual(rig.host.stageHolds, [false])
    }

    func test_aToolWithNoPanelShowsItsTitleAndWhatItIsFor() throws {
        let image = try ToolPicture.draw(ToolSummaryView(id: "stamps"), height: 120)
        XCTAssertGreaterThan(try ToolPicture.ink(image), 100)

        let none = try ToolPicture.draw(ToolSummaryView(id: "nothing"), height: 120)
        XCTAssertEqual(try ToolPicture.ink(none), 0)
    }
}
#endif
