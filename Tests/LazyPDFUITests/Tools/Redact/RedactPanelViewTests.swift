#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Redact panel: the view is drawn at the width of the inspector, empty, with marks and with a result, and
// for a file that cannot be changed. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Redact.

@MainActor
final class RedactPanelViewTests: XCTestCase {
    private func ink(_ model: RedactModel, height: Int = 1200) throws -> Int {
        try ToolPicture.ink(try ToolPicture.draw(RedactPanelView(model: model), height: height))
    }

    func test_theEmptyPanelAndOneWithMarksAreDrawn() async throws {
        let rig = try ToolViewRig(PdfFromText.create("Write to ann@example.com today.", fonts: StandInFonts()).bytes)
        let model = RedactModel(fonts: nil, images: nil)
        model.attach(rig.tab, rig.viewer, rig.host)
        let empty = try ink(model)

        await model.markKind()

        XCTAssertGreaterThan(empty, 500)
        XCTAssertFalse(model.marks.isEmpty)
        XCTAssertGreaterThan(try ink(model), empty)
    }

    func test_aFileThatCannotBeChangedSaysSoInsteadOfOfferingTheTools() throws {
        let session = try PdfEditSession.open(StandInPdfs.text(1))
        let document = session.document
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: .print, strength: .aes256,
                                          firstId: [UInt8](repeating: 7, count: 16))
        let locked = try document.saveRewrite(PdfSaveOptions(security: security))
        let rig = try ToolViewRig(locked)
        let model = RedactModel(fonts: nil, images: nil)
        model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertTrue(model.restricted)
        XCTAssertGreaterThan(try ink(model, height: 200), 100)
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("redact")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "redact", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertGreaterThan(try ToolPicture.ink(try ToolPicture.draw(panel.view, height: 1200)), 500)
        XCTAssertNotNil(panel.model.action)
    }
}
#endif
