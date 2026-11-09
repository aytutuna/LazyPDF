#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Certificates panel: the view is drawn at the width of the inspector with the keychain choice, with the
// .p12 choice and with a time stamp. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Certificates.

@MainActor
final class CertificatesPanelViewTests: XCTestCase {
    private func model(_ rig: ToolViewRig) -> CertificatesModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let made = CertificatesModel(trust: SignatureTrust(directory: folder), transport: { Quiet() },
                                     importIdentity: { _, _ in throw InvalidDataException("No identity.") })
        made.attach(rig.tab, rig.viewer, rig.host)
        return made
    }

    private final class Quiet: SigningTransport {
        var lastFailure: String? { nil }
        func cancel() {}
        func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? { nil }
        func get(_ url: String) -> [UInt8]? { nil }
    }

    private func ink(_ model: CertificatesModel, height: Int = 1100) throws -> Int {
        try ToolPicture.ink(try ToolPicture.draw(CertificatesPanelView(model: model), height: height))
    }

    func test_thePanelIsDrawnForEachWayOfSigning() throws {
        let rig = try ToolViewRig()
        let model = model(rig)
        let keychain = try ink(model)

        model.useKeychain = false
        model.timestamp = true
        model.timestampUrl = "ftp://nowhere"

        XCTAssertGreaterThan(keychain, 300)
        XCTAssertGreaterThan(try ink(model), 300)
        XCTAssertFalse(model.urlNote.isEmpty)
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("certificates")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "certificates", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertGreaterThan(try ToolPicture.ink(try ToolPicture.draw(panel.view, height: 1100)), 300)
        XCTAssertNotNil(panel.model.action)
    }
}
#endif
