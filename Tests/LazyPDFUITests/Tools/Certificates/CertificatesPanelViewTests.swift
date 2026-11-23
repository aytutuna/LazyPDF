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
    private func model(_ rig: ToolViewRig, saved: Int = 0) throws -> CertificatesModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codec = ImageIOCodec()
        let store = SavedSignatures(directory: folder.appendingPathComponent("Signatures"), codec: codec)
        let black = PdfRgbaImage(20, 10, (0..<20 * 10).flatMap { _ in [UInt8(0), 0, 0, 255] })
        for _ in 0..<saved { try store.add(.signature, black) }
        let made = CertificatesModel(trust: SignatureTrust(directory: folder), store: store,
                                     system: SystemSignature(), codec: codec, transport: { Quiet() },
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
        let model = try model(rig)
        let keychain = try ink(model)

        model.useKeychain = false
        model.timestamp = true
        model.timestampUrl = "ftp://nowhere"

        XCTAssertGreaterThan(keychain, 300)
        XCTAssertGreaterThan(try ink(model), 300)
        XCTAssertFalse(model.urlNote.isEmpty)
    }

    func test_aPictureLookShowsTheSavedSignaturesOrSaysThereAreNone() throws {
        let empty = try model(try ToolViewRig())
        empty.setPlace(1)
        let plain = try ink(empty)
        empty.lookIndex = 1
        let note = try ink(empty)
        let full = try model(try ToolViewRig(), saved: 2)
        full.setPlace(1)
        full.lookIndex = 1
        let list = try ink(full)

        XCTAssertTrue(empty.needsPicture)
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertEqual(full.rows.count, 2)
        XCTAssertNotEqual(note, plain)
        XCTAssertNotEqual(list, note)
    }

    func test_theLookIsNotOfferedForAnInvisibleSignature() throws {
        let model = try model(try ToolViewRig(), saved: 1)
        model.setPlace(0)
        model.lookIndex = 0
        let textOnly = try ink(model)

        model.lookIndex = 2

        XCTAssertFalse(model.showsLook)
        XCTAssertEqual(try ink(model), textOnly)
    }

    func test_theSheetThatMakesAPictureIsDrawnFromTheCertificatesModel() throws {
        let model = try model(try ToolViewRig())
        model.makeNew()
        model.maker.setName("Ada")

        let sheet = SignatureMakerView(maker: model.maker, use: { model.useMade() }, cancel: { model.cancelMaker() },
                                       choosePicture: { await model.chooseMakerPicture() })

        XCTAssertGreaterThan(try ToolPicture.ink(try ToolPicture.draw(sheet, height: 560)), 200)
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
