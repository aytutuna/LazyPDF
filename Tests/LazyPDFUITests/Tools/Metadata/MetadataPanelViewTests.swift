#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Properties panel: the view is drawn at the width of the inspector after its model is attached, with the
// words of its sections on it. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Metadata.

@MainActor
final class MetadataPanelViewTests: XCTestCase {
    func test_thePanelIsDrawnWithItsLabelsAndFields() throws {
        let rig = try ToolViewRig()
        let model = MetadataModel()
        model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(MetadataPanelView(model: model), height: 1100)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 2000)
    }

    func test_whatIsTypedChangesThePicture() throws {
        let rig = try ToolViewRig()
        let model = MetadataModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        let before = try ToolPicture.ink(try ToolPicture.draw(MetadataPanelView(model: model), height: 1100))

        model.keywords = "alpha, beta, gamma"
        model.created = Date(timeIntervalSince1970: 1_700_000_000)
        let after = try ToolPicture.ink(try ToolPicture.draw(MetadataPanelView(model: model), height: 1100))

        XCTAssertNotEqual(before, after)
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("metadata")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "metadata", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(panel.view, height: 1100)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 2000)
        XCTAssertEqual(panel.model.action?.text, "Save properties")
    }
}
#endif
