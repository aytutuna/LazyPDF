#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Comment panel: the view is drawn at the width of the inspector after its model is attached, then with
// the stamp row and the picked mark's row. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Comment.

@MainActor
final class CommentPanelViewTests: XCTestCase {
    func test_thePanelIsDrawnWithItsSectionsAndPalette() throws {
        let rig = try ToolViewRig()
        let model = CommentModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(CommentPanelView(model: model), height: 1300)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 400)
    }

    func test_pickingTheStampToolAddsItsRow() throws {
        let rig = try ToolViewRig()
        let model = CommentModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)
        let before = try ToolPicture.ink(try ToolPicture.draw(CommentPanelView(model: model), height: 1300))

        model.pick(.stamp)
        let after = try ToolPicture.ink(try ToolPicture.draw(CommentPanelView(model: model), height: 1300))

        XCTAssertTrue(model.showsStamp)
        XCTAssertNotEqual(after, before)
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("comment")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "comment", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(panel.view, height: 1300)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 400)
        XCTAssertEqual(panel.model.action?.text, "Flatten comments")
    }

    func test_theLineToolAddsItsHeadAndDashControls() throws {
        let rig = try ToolViewRig()
        let model = CommentModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)
        model.pick(.textBox)
        let before = try ToolPicture.ink(try ToolPicture.draw(CommentPanelView(model: model), height: 1600))

        model.pick(.line)
        let after = try ToolPicture.ink(try ToolPicture.draw(CommentPanelView(model: model), height: 1600))

        XCTAssertTrue(model.showsHeads)
        XCTAssertTrue(model.showsDash)
        XCTAssertNotEqual(after, before)
    }

    func test_aSelectedPolygonShowsTheAddAndRemovePointButtons() throws {
        let rig = try ToolViewRig()
        let marker = Marker(rig.tab.document, StandInFonts(), author: "Ana", date: DateTimeOffset(2026, 11, 4, 10, 0, 0))
        _ = try marker.add(.polygon, 0, [ViewPoint(100, 100), ViewPoint(300, 100), ViewPoint(300, 300), ViewPoint(100, 300)], MarkStyle())
        _ = try rig.tab.commit("Polygon")
        let model = CommentModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)
        model.pick(.edit)
        let before = try ToolPicture.ink(try ToolPicture.draw(CommentPanelView(model: model), height: 1600))

        model.select(try XCTUnwrap(model.marks.first))
        let after = try ToolPicture.ink(try ToolPicture.draw(CommentPanelView(model: model), height: 1600))

        XCTAssertEqual(model.selected?.canAddPoint, true)
        XCTAssertNotEqual(after, before)
    }
}
#endif
