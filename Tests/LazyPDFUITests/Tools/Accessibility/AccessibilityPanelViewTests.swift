#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the accessibility panel: the view is drawn at the width of the inspector with the result of the check, and
// again in each of its other views. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Accessibility.

@MainActor
final class AccessibilityPanelViewTests: XCTestCase {
    private func shown(_ view: AccessibilityView = .check) async throws -> (AccessibilityModel, ToolViewRig) {
        let rig = try ToolViewRig(StandInPdfs.text(2))
        let model = AccessibilityModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        for _ in 0..<300 where model.rows.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        model.setView(view)
        return (model, rig)
    }

    func test_theCheckIsDrawnWithItsRows() async throws {
        let (model, _) = try await shown()

        let image = try ToolPicture.draw(AccessibilityPanelView(model: model), height: 1600)

        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertGreaterThan(try ToolPicture.ink(image), 500)
    }

    func test_theOtherViewsAreDrawn() async throws {
        for view in [AccessibilityView.tags, .figures, .read] {
            let (model, _) = try await shown(view)

            let image = try ToolPicture.draw(AccessibilityPanelView(model: model), height: 400)

            XCTAssertGreaterThan(try ToolPicture.ink(image), 100, "\(view)")
        }
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("accessibility")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "accessibility", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(panel.view, height: 400)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 100)
        XCTAssertEqual(panel.model.action?.text, "Check")
    }
}
#endif
