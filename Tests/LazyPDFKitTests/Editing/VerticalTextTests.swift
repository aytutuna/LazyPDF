import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/VerticalTextTests.cs: the same cases.

final class VerticalTextTests: XCTestCase {
    private let toUnicode =
        "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def /CMapType 2 def " +
        "1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfrange <0041> <005A> <0041> endbfrange endcmap end end"

    private func open(_ encoding: String) throws -> PdfEditSession {
        let toUnicode = self.toUnicode
        return try PdfEditSession.open(EditKit.file("BT /F3 12 Tf 100 700 Td <004100420043> Tj ET", more: { pdf in
            pdf.obj(7, "<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /\(encoding) /DescendantFonts [<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial " +
                "/CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 600>>] /ToUnicode 8 0 R>>")
            pdf.stream(8, "", toUnicode)
        }, resources: "/Font <</F1 5 0 R /F3 7 0 R>>"))
    }

    func test_verticalTextIsLeftAlone() throws {
        let session = try open("Identity-V")
        let editor = try PageEditor(session, 0)
        XCTAssertEqual(DotNetText.trim(try editor.text.text), "ABC")
        let result = try editor.replaceText(TextRange(0, 3), "XYZ")
        XCTAssertFalse(result.done)
        XCTAssertEqual(result.problem, EditingText.vertical)
        XCTAssertFalse(session.canUndo)
    }

    func test_horizontalCidTextWithoutAnEmbeddedProgramTakesLettersItsMapShows() throws {
        let session = try open("Identity-H")
        let editor = try PageEditor(session, 0)
        let result = try editor.replaceText(TextRange(0, 3), "CAB")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertEqual(DotNetText.trim(try EditKit.text(session)), "CAB")
        // A letter the map does not cover has no code in this font and no source to come from.
        let refused = try PageEditor(session, 0).replaceText(TextRange(0, 3), "abc")
        XCTAssertFalse(refused.done)
        XCTAssertEqual(refused.problem, EditingText.noFont)
    }
}
