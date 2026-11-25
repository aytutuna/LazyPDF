import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactGlyphProbeTests.cs: the same cases. A Type 3 font with anything but plain
// glyph procedures makes the page a picture; the procedures are looked at once, not once per glyph.

final class RedactGlyphProbeTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let paints = "1000 0 d0 q 10000 0 0 10000 20000 20000 cm /Im1 Do Q"
    private let over = PdfRect(240, 240, 360, 360)

    private func type3(_ procedures: String, _ names: String, _ resources: String = "") -> String {
        let count = names.split(separator: " ").count
        let widths = names.split(separator: " ").map { _ in "1000" }.joined(separator: " ")
        return "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <<\(procedures)>> "
            + "/Encoding <</Type /Encoding /Differences [97 \(names)]>> /FirstChar 97 /LastChar \(96 + count) /Widths [\(widths)] \(resources)>>"
    }

    func test_matrixOnTheProcedureStreamMovesNothing() throws {
        let document = try RedactionKit.page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>> /XObject <</Im1 8 0 R>>") { pdf in
            pdf.obj(6, self.type3("/a 7 0 R", "/a", "/Resources <</XObject <</Im1 8 0 R>>>>"))
            pdf.stream(7, "/Matrix [1 0 0 1 900000 0]", self.paints)
            pdf.stream(8, self.imageEntries, self.pixels)
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, over)], "ZQXPIXELSDATA")
    }

    func test_glyphOfASecondFontShownByAProcedureMakesThePagePicture() throws {
        let document = try RedactionKit.page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>>") { pdf in
            pdf.obj(6, self.type3("/a 7 0 R", "/a", "/Resources <</Font <</T2 9 0 R>>>>"))
            pdf.stream(7, "", "1000 0 d0 BT /T2 1000 Tf (a) Tj ET")
            pdf.stream(8, self.imageEntries, self.pixels)
            pdf.obj(9, self.type3("/a 10 0 R", "/a", "/Resources <</XObject <</Im1 8 0 R>>>>"))
            pdf.stream(10, "", self.paints)
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, over)], "ZQXPIXELSDATA")
    }

    func test_procedureThatCallsFormsMakesThePagePicture() throws {
        let document = try RedactionKit.page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>>") { pdf in
            pdf.obj(6, self.type3("/a 7 0 R", "/a", "/Resources <</XObject <</N1 9 0 R /Im1 8 0 R>>>>"))
            pdf.stream(7, "", "1000 0 d0 " + String(repeating: "/N1 Do ", count: 12) + "q 10000 0 0 10000 20000 20000 cm /Im1 Do Q")
            pdf.stream(8, self.imageEntries, self.pixels)
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 1 1]", String(repeating: "n ", count: 900_000))
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, over)], "ZQXPIXELSDATA")
    }

    func test_manyGlyphsOfALongProcedureAreProbedOnce() throws {
        let document = try RedactionKit.page("BT /T3 10 Tf 50 50 Td (\(String(repeating: "a", count: 100))) Tj ET", "/Font <</T3 6 0 R>>") { pdf in
            pdf.obj(6, self.type3("/a 7 0 R", "/a"))
            pdf.stream(7, "", "1000 0 d0 " + String(repeating: "n ", count: 100_000))
        }
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, PdfRect(500, 40, 550, 70))])
        XCTAssertTrue(result.report.flattened.contains(0))
    }
}
