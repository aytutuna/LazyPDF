#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Stamps panel: the view is drawn at the width of the inspector after its model is attached, for each kind of
// stamp. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Stamps.

@MainActor
final class StampsPanelViewTests: XCTestCase {
    func test_eachKindIsDrawnWithItsOwnFields() throws {
        let rig = try ToolViewRig()
        let model = StampsModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        var inks: [Int] = []

        for mode in StampMode.allCases {
            model.setMode(mode)
            inks.append(try ToolPicture.ink(try ToolPicture.draw(StampsPanelView(model: model), height: 1000)))
        }

        XCTAssertTrue(inks.allSatisfy { $0 > 500 })
        XCTAssertEqual(Set(inks).count, inks.count)
        model.detach()
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("stamps")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "stamps", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(panel.view, height: 1000)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 500)
        XCTAssertEqual(panel.model.action?.text, "Add watermark")
        panel.model.detach()
    }
}
#endif
