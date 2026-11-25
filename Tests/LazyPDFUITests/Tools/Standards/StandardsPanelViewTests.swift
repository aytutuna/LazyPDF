#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the PDF/A panel: the view is drawn at the width of the inspector before a check and with its verdict and
// rows after one. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Standards.

@MainActor
final class StandardsPanelViewTests: XCTestCase {
    private func ink(_ model: StandardsModel, height: Int = 1400) throws -> Int {
        try ToolPicture.ink(try ToolPicture.draw(StandardsPanelView(model: model), height: height))
    }

    func test_thePanelIsDrawnBeforeAndAfterACheck() async throws {
        let rig = try ToolViewRig()
        let model = StandardsModel(fonts: nil)
        model.attach(rig.tab, rig.viewer, rig.host)
        let before = try ink(model)

        await model.action!.run()

        XCTAssertGreaterThan(before, 300)
        XCTAssertTrue(model.showsResult)
        XCTAssertGreaterThan(try ink(model), before)
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("standards")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "standards", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertGreaterThan(try ToolPicture.ink(try ToolPicture.draw(panel.view, height: 1400)), 300)
        XCTAssertNotNil(panel.model.action)
    }
}
#endif
