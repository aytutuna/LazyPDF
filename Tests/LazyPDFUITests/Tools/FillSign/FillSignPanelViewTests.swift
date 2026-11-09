#if canImport(SwiftUI) && canImport(CoreGraphics)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Fill and sign panel and its sheet: the views are drawn after their models are attached. The models have the
// real tests, in Tests/LazyPDFAppTests/Tools/FillSign.

@MainActor
final class FillSignPanelViewTests: XCTestCase {
    private func panel() throws -> (ToolPanel, ToolViewRig) {
        let rig = try ToolViewRig()
        let folders = StandInFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("fillsign-\(UUID().uuidString)"))
        let context = ToolContext(info: ToolCatalog.find("fillsign")!, folders: folders)
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "fillsign", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)
        return (panel, rig)
    }

    func test_theRegistryMakesThePanelAndItIsDrawnForEachKind() throws {
        let (panel, _) = try panel()
        let model = try XCTUnwrap(panel.model as? FillSignModel)

        let signature = try ToolPicture.ink(try ToolPicture.draw(panel.view, height: 500))
        model.selectKind(.text)
        model.words = "Approved"
        let text = try ToolPicture.ink(try ToolPicture.draw(panel.view, height: 500))

        XCTAssertGreaterThan(signature, 300)
        XCTAssertGreaterThan(text, 300)
        XCTAssertNotEqual(signature, text)
        XCTAssertEqual(model.action?.text, "Place on page")
        panel.model.detach()
    }

    func test_aPictureWithSeeThroughPartsIsDrawn() throws {
        var pixels = [UInt8](repeating: 0, count: 20 * 10 * 4)
        for i in 0..<20 * 5 { pixels[i * 4 + 3] = 255 }
        let image = PdfRgbaImage(20, 10, pixels)

        let drawn = try ToolPicture.draw(SignaturePicture(image: image), width: 60, height: 40)

        XCTAssertGreaterThan(try ToolPicture.ink(drawn), 100)
        XCTAssertEqual(SignatureImage.cgImage(image)?.width, 20)
        XCTAssertNil(SignatureImage.cgImage(PdfRgbaImage(20, 10, [0, 0, 0, 0])))
    }

    func test_theSheetThatMakesASignatureIsDrawn() throws {
        let (panel, _) = try panel()
        let model = try XCTUnwrap(panel.model as? FillSignModel)
        model.makeNew()
        model.maker.setName("Ada")

        let typed = try ToolPicture.ink(try ToolPicture.draw(SignatureMakerView(model: model), height: 560))
        model.maker.setMode(.draw)
        let drawing = try ToolPicture.ink(try ToolPicture.draw(SignatureMakerView(model: model), height: 560))

        XCTAssertGreaterThan(typed, 200)
        XCTAssertGreaterThan(drawing, 200)
        panel.model.detach()
    }
}
#endif
