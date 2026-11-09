#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Measure panel: the view is drawn at the width of the inspector after its model is attached, empty and
// with a measurement waiting. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Measure.

@MainActor
final class MeasurePanelViewTests: XCTestCase {
    func test_thePanelIsDrawnWithItsScaleAndOptions() throws {
        let rig = try ToolViewRig()
        let model = MeasureModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(MeasurePanelView(model: model), height: 700)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 300)
    }

    func test_aBadScaleAddsItsWarning() throws {
        let rig = try ToolViewRig()
        let model = MeasureModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)
        let before = try ToolPicture.ink(try ToolPicture.draw(MeasurePanelView(model: model), height: 700))

        model.setPageValue("0")
        let after = try ToolPicture.ink(try ToolPicture.draw(MeasurePanelView(model: model), height: 700))

        XCTAssertTrue(model.scaleProblem)
        XCTAssertNotEqual(after, before)
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("measure")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "measure", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(panel.view, height: 700)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 300)
        XCTAssertEqual(panel.model.action?.text, "Add to page")
    }
}
#endif
