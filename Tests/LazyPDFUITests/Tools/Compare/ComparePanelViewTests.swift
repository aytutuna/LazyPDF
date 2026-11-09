#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Compare panel: the view is drawn at the width of the inspector before anything is compared and again
// with a result and its list. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Compare. The sheet holds the
// platform's scroll views, which the renderer here does not draw.

@MainActor
final class ComparePanelViewTests: XCTestCase {
    private func makeModel() -> CompareModel {
        CompareModel(renderers: { StandInRenderer() }, fonts: StandInFonts())
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws -> ToolFile {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return ToolFile(url: url)
    }

    func test_thePanelIsDrawnBeforeAndAfterAComparison() async throws {
        let rig = try ToolViewRig(StandInPdfs.text(2))
        let model = makeModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        let before = try ToolPicture.ink(try ToolPicture.draw(ComparePanelView(model: model), height: 700))
        XCTAssertGreaterThan(before, 200)

        model.choose(try file("other.pdf", StandInPdfs.text(3)))
        await model.action!.run()
        let after = try ToolPicture.ink(try ToolPicture.draw(ComparePanelView(model: model), height: 900))

        XCTAssertNotNil(model.shown)
        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertGreaterThan(after, before)
    }

    func test_theListOfDifferencesIsDrawnWithItsRows() throws {
        let rows = [
            ChangeRow(kind: .added, title: "other", subtitle: "Added · Page 1", oldPage: -1, newPage: 0, oldBoxes: [], newBoxes: []),
            ChangeRow(kind: .removed, title: "gone", subtitle: "Removed · Page 2", oldPage: 1, newPage: -1, oldBoxes: [], newBoxes: []),
            ChangeRow(kind: nil, title: "Looks different", subtitle: "Page 1, 40 % down", oldPage: 0, newPage: 0, oldBoxes: [], newBoxes: []),
        ]

        let image = try ToolPicture.draw(ChangeListView(rows: rows) { _ in }, height: 200)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 200)
    }

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("compare")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "compare", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(panel.view, height: 700)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 200)
        XCTAssertEqual(panel.model.action?.text, "Compare")
    }
}
#endif
