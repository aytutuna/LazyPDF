#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// Smoke tests of the Combine panel: the view is drawn at the width of the inspector after its model is attached. The model has the
// real tests, in Tests/LazyPDFAppTests/Tools/Combine.

@MainActor
final class CombineViewTests: XCTestCase {
    func test_theCombinePanelIsDrawnWithItsListAndTheSplitForm() throws {
        let rig = try ToolViewRig(StandInPdfs.text(3))
        let model = CombineModel()
        model.attach(rig.tab, rig.viewer, rig.host)

        let combine = try ToolPicture.ink(try ToolPicture.draw(CombinePanelView(model: model), height: 500))
        model.setSplitting(true)
        let split = try ToolPicture.ink(try ToolPicture.draw(CombinePanelView(model: model), height: 500))

        XCTAssertGreaterThan(combine, 300)
        XCTAssertGreaterThan(split, 300)
        XCTAssertEqual(model.entries.count, 1)
    }

    func test_theRegistryMakesThePanelOfTheCombineTool() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("combine")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "combine", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertNil(panel.stage)
        XCTAssertEqual(panel.model.action?.text, "Combine files")
    }
}
#endif
