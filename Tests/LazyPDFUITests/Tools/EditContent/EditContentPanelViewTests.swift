#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Edit text and pictures panel: the view is drawn at the width of the inspector after its model is attached.
// The model has the real tests, in Tests/LazyPDFAppTests/Tools/EditContent.

@MainActor
final class EditContentPanelViewTests: XCTestCase {
    func test_thePanelIsDrawnWithItsModesAndTheReplaceFields() throws {
        let rig = try ToolViewRig()
        let model = EditContentModel()
        model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(EditContentPanelView(model: model), height: 900)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 500)
        XCTAssertEqual(model.hint, "Click text or a picture to change it. Drag to select several.")
        model.detach()
    }

    func test_pickingATextBoxShowsTheTextSection() throws {
        let rig = try ToolViewRig()
        let model = EditContentModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        let plain = try ToolPicture.ink(try ToolPicture.draw(EditContentPanelView(model: model), height: 900))

        model.selectMode(.textBox)
        let withText = try ToolPicture.ink(try ToolPicture.draw(EditContentPanelView(model: model), height: 900))

        XCTAssertTrue(model.sections.text)
        XCTAssertNotEqual(plain, withText)
        model.detach()
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("editcontent")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "editcontent", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(panel.view, height: 900)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 500)
        XCTAssertNil(panel.model.action)
        panel.model.detach()
    }
}
#endif
