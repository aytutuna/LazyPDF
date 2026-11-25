#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Protect panel: the view is drawn at the width of the inspector in each of its modes. The model has the
// real tests, in Tests/LazyPDFAppTests/Tools/Protect.

@MainActor
final class ProtectPanelViewTests: XCTestCase {
    private func ink(_ model: ProtectModel, height: Int = 900) throws -> Int {
        try ToolPicture.ink(try ToolPicture.draw(ProtectPanelView(model: model), height: height))
    }

    func test_thePasswordFormLimitsAndEncryptionAreDrawn() throws {
        let rig = try ToolViewRig()
        let model = ProtectModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        let plain = try ink(model)

        model.limited = true
        model.openPassword = "Tr0ub4dor&3x"

        XCTAssertGreaterThan(plain, 500)
        XCTAssertGreaterThan(try ink(model), plain)
    }

    func test_theCertificateModeDrawsItsListAndNote() throws {
        let rig = try ToolViewRig()
        let model = ProtectModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        model.mode = .password
        let password = try ink(model)

        model.mode = .certificates

        XCTAssertGreaterThan(try ink(model), 100)
        XCTAssertGreaterThan(password, 100)
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("protect")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "protect", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertGreaterThan(try ToolPicture.ink(try ToolPicture.draw(panel.view, height: 900)), 300)
        XCTAssertNotNil(panel.model.action)
    }
}
#endif
