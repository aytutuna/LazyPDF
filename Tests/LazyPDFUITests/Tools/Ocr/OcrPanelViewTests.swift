#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Make searchable panel: the view is drawn at the width of the inspector while the pages are checked and
// again with the list. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Ocr.

@MainActor
final class OcrPanelViewTests: XCTestCase {
    private func makeModel() -> OcrModel {
        let state = OcrLanguageState(installed: [OcrLanguage(tag: "en-US", name: "English")], missing: ["Turkish"])
        return OcrModel(languages: { state })
    }

    func test_thePanelIsDrawnWhileThePagesAreCheckedAndWithTheirList() async throws {
        let rig = try ToolViewRig(StandInPdfs.text(3))
        let model = makeModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        let looking = try ToolPicture.ink(try ToolPicture.draw(OcrPanelView(model: model), height: 700))
        XCTAssertGreaterThan(looking, 200)

        for _ in 0..<300 where model.isLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        let listed = try ToolPicture.ink(try ToolPicture.draw(OcrPanelView(model: model), height: 700))

        XCTAssertEqual(model.rows.count, 3)
        XCTAssertGreaterThan(listed, 200)
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("ocr")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "ocr", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(panel.view, height: 700)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 200)
        XCTAssertEqual(panel.model.action?.text, "Make searchable")
    }
}
#endif
