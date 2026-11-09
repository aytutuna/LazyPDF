#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Export panel: drawn at the width of the inspector for the formats that show other fields. The model has
// the real tests, in Tests/LazyPDFAppTests/Tools/Export.

@MainActor
final class ExportPanelViewTests: XCTestCase {
    private func ink(_ model: ExportModel) throws -> Int {
        try ToolPicture.ink(try ToolPicture.draw(ExportPanelView(model: model), height: 700))
    }

    func test_thePanelIsDrawnAndTheFormatsAddTheirFields() throws {
        let rig = try ToolViewRig(StandInPdfs.text(3))
        let model = ExportModel(codec: nil, renderers: { BlankRenderer() })
        model.attach(rig.tab, rig.viewer, rig.host)
        let word = try ink(model)
        XCTAssertGreaterThan(word, 200)

        model.format = .pictures
        let pictures = try ink(model)
        model.picture = .jpeg
        let jpeg = try ink(model)

        XCTAssertGreaterThan(pictures, word)
        XCTAssertGreaterThan(jpeg, pictures)
    }

    func test_aTypedPageThatIsWrongShowsItsReason() throws {
        let rig = try ToolViewRig(StandInPdfs.text(3))
        let model = ExportModel(codec: nil, renderers: { BlankRenderer() })
        model.attach(rig.tab, rig.viewer, rig.host)
        let fine = try ink(model)

        model.scope = .typed
        model.pagesText = "9"

        XCTAssertNotNil(model.blocker)
        XCTAssertGreaterThan(try ink(model), fine)
    }
}
#endif
