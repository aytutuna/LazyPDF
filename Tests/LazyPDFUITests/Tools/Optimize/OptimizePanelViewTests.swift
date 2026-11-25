#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Make smaller panel: drawn at the width of the inspector while the file is searched, with the list, and
// with the custom settings. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Optimize.

@MainActor
final class OptimizePanelViewTests: XCTestCase {
    func test_thePanelIsDrawnWhileSearchingAndWithTheList() async throws {
        let rig = try ToolViewRig(StandInPdfs.text(3))
        let model = OptimizeModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        let looking = try ToolPicture.ink(try ToolPicture.draw(OptimizePanelView(model: model), height: 700))
        XCTAssertGreaterThan(looking, 200)

        await model.showAudit().value
        let listed = try ToolPicture.ink(try ToolPicture.draw(OptimizePanelView(model: model), height: 700))

        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertGreaterThan(listed, looking)
    }

    func test_theCustomSettingsAddToThePicture() throws {
        let rig = try ToolViewRig()
        let model = OptimizeModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        let plain = try ToolPicture.ink(try ToolPicture.draw(OptimizePanelView(model: model), height: 900))

        model.preset = .custom
        let custom = try ToolPicture.ink(try ToolPicture.draw(OptimizePanelView(model: model), height: 900))

        XCTAssertGreaterThan(custom, plain)
    }
}
#endif
