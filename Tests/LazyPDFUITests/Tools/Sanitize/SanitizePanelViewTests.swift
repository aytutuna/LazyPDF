#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Clean for sharing panel: the view is drawn at the width of the inspector, first while the file is
// searched and then with the list of what was found. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Sanitize.

@MainActor
final class SanitizePanelViewTests: XCTestCase {
    private func titled() throws -> [UInt8] {
        let session = try PdfEditSession.open(StandInPdfs.text(2))
        var metadata = DocumentMetadata.read(session.document)
        metadata.title = "Salary review"
        try metadata.write(session.document)
        try session.commit("Title")
        return session.current
    }

    func test_thePanelSaysItIsLookingThenListsWhatItFound() async throws {
        let rig = try ToolViewRig(try titled())
        let model = SanitizeModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        let looking = try ToolPicture.ink(try ToolPicture.draw(SanitizePanelView(model: model), height: 600))
        XCTAssertGreaterThan(looking, 500)

        await model.scan().value
        let found = try ToolPicture.ink(try ToolPicture.draw(SanitizePanelView(model: model), height: 600))

        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertGreaterThan(found, looking)
    }

    func test_theChoiceOfWhereTheResultGoesIsDrawn() throws {
        let rig = try ToolViewRig()
        let output = OutputChoice()
        output.configure(rig.tab, removesSignatures: true)

        let image = try ToolPicture.draw(OutputChoiceView(output: output), height: 140)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 300)
    }
}
#endif
