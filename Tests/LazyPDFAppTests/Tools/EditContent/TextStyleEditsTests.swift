import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/Tools/edit/TextStyleEditsTests.cs: restyling a block through the panel's calls, on files whose
// text is placed the way real ones place it.

@MainActor
final class TextStyleEditsTests: XCTestCase {
    private func open(_ bytes: [UInt8]) throws -> DocumentTab {
        DocumentTab(session: try PdfEditSession.open(bytes), renderer: FakeRenderer(), url: nil, title: "t.pdf")
    }

    private func makeEdits(_ tab: DocumentTab) -> ContentEdits {
        ContentEdits(tab, fonts: FakeFonts(), codec: FakeCodec())
    }

    private func block(_ tab: DocumentTab) throws -> TextObject {
        try XCTUnwrap(try PageEditor(tab.session, 0).objects[0] as? TextObject)
    }

    func test_aFontChangeKeepsTheLinesOfTheBlock() async throws {
        for (bold, italic) in [(true, false), (false, true)] {
            let tab = try open(EditPdf.make(EditPdf.paragraph))
            let before = try block(tab)

            let outcome = try makeEdits(tab).style(0, before.id, TextStyleChange(bold: bold ? true : nil, italic: italic ? true : nil))

            XCTAssertTrue(outcome.done, outcome.problem ?? "")
            let after = try block(tab)
            XCTAssertEqual(after.lines.count, 3)
            XCTAssertEqual(after.lines.map(\.text), before.lines.map(\.text))
            XCTAssertLessThan(after.bounds.right, 612)
            XCTAssertEqual(after.lines[2].bounds.bottom, before.lines[2].bounds.bottom, accuracy: 1)
        }
    }

    func test_aSizeIsTakenInPageUnitsWhateverScalesTheText() async throws {
        let tab = try open(EditPdf.make("BT /F1 1 Tf 12 0 0 12 50 700 Tm (Scaled text) Tj ET"))
        let start = try block(tab)
        XCTAssertEqual(start.size, 12, accuracy: 1)

        let outcome = try makeEdits(tab).style(0, start.id, TextStyleChange(size: 14))

        XCTAssertTrue(outcome.done, outcome.problem ?? "")
        XCTAssertEqual(try block(tab).size, 14, accuracy: 1)
        XCTAssertTrue(try PageEditor(tab.session, 0).text.text.contains("Scaled text"))
    }

    func test_aSizeUnderAScalingCmIsTakenInPageUnits() async throws {
        let tab = try open(EditPdf.make("q 0.5 0 0 0.5 0 0 cm BT /F1 24 Tf 100 1400 Td (Halved text) Tj ET Q"))
        let start = try block(tab)
        XCTAssertEqual(start.size, 12, accuracy: 1)

        XCTAssertTrue(try makeEdits(tab).style(0, start.id, TextStyleChange(size: 8)).done)

        XCTAssertEqual(try block(tab).size, 8, accuracy: 1)
    }

    func test_aColourReachesEveryLine() async throws {
        let tab = try open(EditPdf.make(EditPdf.paragraph))

        XCTAssertTrue(try makeEdits(tab).style(0, try block(tab).id, TextStyleChange(color: RgbColor(200, 30, 30))).done)

        XCTAssertEqual(try block(tab).color, RgbColor(200, 30, 30))
        XCTAssertEqual(try block(tab).lines.count, 3)
    }
}
