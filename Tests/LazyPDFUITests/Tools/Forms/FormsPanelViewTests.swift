#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Forms panel: the view is drawn at the width of the inspector after its model is attached, in both modes.
// The model has the real tests, in Tests/LazyPDFAppTests/Tools/Forms.

@MainActor
final class FormsPanelViewTests: XCTestCase {
    private func form() throws -> [UInt8] {
        let document = try PdfDocument.open(StandInPdfs.text(2))
        let form = PdfForm.read(document, StandInFonts())
        try form.addField(FieldSpec(.text, "name", 0, PdfRect(60, 640, 300, 660), flags: .required))
        try form.addField(FieldSpec(.checkBox, "agree", 0, PdfRect(60, 580, 74, 594)))
        try form.addField(FieldSpec(.comboBox, "city", 0, PdfRect(60, 510, 200, 528), options: [FieldOption("Ankara"), FieldOption("Izmir")]))
        return try document.saveRewrite(PdfSaveOptions())
    }

    func test_thePanelIsDrawnForFillingAndForEditing() throws {
        let rig = try ToolViewRig(try form())
        let model = FormsModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)

        let filling = try ToolPicture.ink(try ToolPicture.draw(FormsPanelView(model: model), height: 900))
        model.setDesigning(true)
        model.select("name", 0)
        let editing = try ToolPicture.ink(try ToolPicture.draw(FormsPanelView(model: model), height: 900))

        XCTAssertGreaterThan(filling, 500)
        XCTAssertGreaterThan(editing, 500)
        XCTAssertNotEqual(filling, editing)
    }

    func test_aFileWithoutFieldsShowsItsSummary() throws {
        let rig = try ToolViewRig()
        let model = FormsModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(FormsPanelView(model: model), height: 300)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 300)
        XCTAssertEqual(model.summary, "This file has no form fields.")
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig(try form())
        let context = ToolContext(info: ToolCatalog.find("forms")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "forms", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(panel.view, height: 900)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 500)
        XCTAssertEqual(panel.model.action?.text, "Flatten form")
        panel.model.detach()
    }
}
#endif
