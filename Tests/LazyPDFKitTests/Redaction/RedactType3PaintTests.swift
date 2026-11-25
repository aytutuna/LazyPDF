import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactType3PaintTests.cs: the same cases. A glyph procedure paints where it
// pleases (ISO 32000-1 9.6.5): unless it is plain shapes near its box, the page becomes a picture.

final class RedactType3PaintTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"

    private func type3(_ procedures: String, _ names: String, _ resources: String = "") -> String {
        let count = names.split(separator: " ").count
        let widths = names.split(separator: " ").map { _ in "1000" }.joined(separator: " ")
        return "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <<\(procedures)>> "
            + "/Encoding <</Type /Encoding /Differences [97 \(names)]>> /FirstChar 97 /LastChar \(96 + count) /Widths [\(widths)] \(resources)>>"
    }

    private func drawn() throws -> PdfDocument {
        try RedactionKit.page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>> /XObject <</Im1 8 0 R>>") { pdf in
            pdf.obj(6, self.type3("/a 7 0 R", "/a", "/Resources <</XObject <</Im1 8 0 R>>>>"))
            pdf.stream(7, "", "1000 0 d0 q 10000 0 0 10000 20000 20000 cm /Im1 Do Q")
            pdf.stream(8, self.imageEntries, self.pixels)
        }
    }

    func test_pictureDrawnByAGlyphWhoseBoxIsClearOfTheMarkMakesThePagePicture() throws {
        let document = try drawn()
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, PdfRect(240, 240, 360, 360))], "ZQXPIXELSDATA")
    }

    func test_shapesDrawnFarFromTheGlyphMakeThePagePictureWhenTheyMeetTheMark() throws {
        let document = try RedactionKit.page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>>") { pdf in
            pdf.obj(6, self.type3("/a 7 0 R", "/a"))
            pdf.stream(7, "", "1000 0 d0 20000 20000 1000 1000 re f")
        }
        let elsewhere = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(400, 400, 500, 500))])
        XCTAssertEqual(elsewhere.report.glyphs, 0)
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, PdfRect(240, 240, 360, 360))])
    }

    func test_glyphOfAType3FontUnderTheMarkMakesThePagePicture() throws {
        let document = try RedactionKit.page("BT /T3 10 Tf 50 50 Td (ab) Tj ET", "/Font <</T3 6 0 R>>") { pdf in
            pdf.obj(6, self.type3("/a 7 0 R /b 8 0 R", "/a /b"))
            pdf.stream(7, "", "1000 0 d0 100 100 800 800 re f")
            pdf.stream(8, "", "1000 0 0 0 1000 1000 d1 100 100 800 800 re f")
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, PdfRect(40, 40, 58, 70))])
    }

    func test_type3GlyphOutsideTheMarksKeepsThePageAsText() throws {
        let document = try RedactionKit.page("BT /T3 10 Tf 50 50 Td (a) Tj ET BT /F1 12 Tf 300 300 Td (ZQXWORD) Tj ET", "/Font <</T3 6 0 R>>") { pdf in
            pdf.obj(6, self.type3("/a 7 0 R", "/a"))
            pdf.stream(7, "", "1000 0 d0 100 100 800 800 re f")
        }
        let result = try PdfRedactor(document).apply([try RedactionKit.markOf(document, 0, "ZQXWORD")])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
    }

    func test_procedureOutsideTheEncodingMakesThePagePicture() throws {
        let document = try RedactionKit.page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>> /XObject <</Im1 9 0 R>>") { pdf in
            pdf.obj(6, self.type3("/a 7 0 R /evil 8 0 R", "/a"))
            pdf.stream(7, "", "1000 0 d0 100 100 800 800 re f")
            pdf.stream(8, "", "1000 0 d0 q 1000 0 0 1000 0 0 cm /Im1 Do Q")
            pdf.stream(9, self.imageEntries, self.pixels)
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, PdfRect(40, 40, 58, 70))], "ZQXPIXELSDATA")
    }

    func test_fontMatrixThatTurnsTheGlyphMakesThePagePicture() throws {
        let document = try RedactionKit.page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>>") { pdf in
            pdf.obj(6, self.type3("/a 7 0 R", "/a").replacingOccurrences(of: "[0.001 0 0 0.001 0 0]", with: "[0 0.01 -0.01 0 0 0]"))
            pdf.stream(7, "", "1000 0 d0 100 100 800 800 re f")
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, PdfRect(40, 40, 58, 70))])
    }

    func test_verifyReportsAGlyphWhoseProcedurePaintsUnderAMark() throws {
        let document = try drawn()
        let problems = PdfRedactor.verify(try document.saveRewrite(), [RedactionMark.fromRect(0, PdfRect(240, 240, 360, 360))], []).problems
        XCTAssertTrue(problems.contains(RedactionText.notFollowed(0)))
    }

    func test_procedureThatPaintsAPictureInAFormMakesThePagePicture() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R /Im1 9 0 R>> /Font <</T3 7 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800]", "BT /T3 10 Tf 50 50 Td (a) Tj ET BT /T3 10 Tf 200 200 Td (b) Tj ET")
            pdf.obj(7, self.type3("/a 8 0 R /b 10 0 R", "/a /b"))
            pdf.stream(8, "", "1000 0 d0 q 1000 0 0 1000 0 0 cm /Im1 Do Q")
            pdf.stream(9, self.imageEntries, self.pixels)
            pdf.stream(10, "", "1000 0 d0 0 0 500 500 re f")
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, PdfRect(40, 40, 80, 80))], "ZQXPIXELSDATA")
    }
}
