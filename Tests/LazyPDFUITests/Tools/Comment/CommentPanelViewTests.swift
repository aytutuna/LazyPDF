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

        XCTAssertGreaterThan(try ToolPicture.ink(image), 1000)
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

        XCTAssertGreaterThan(try ToolPicture.ink(image), 1000)
        XCTAssertEqual(panel.model.action?.text, "Flatten comments")
    }
}
#endif
