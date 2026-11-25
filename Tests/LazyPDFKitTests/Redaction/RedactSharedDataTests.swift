import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactSharedDataTests.cs: the same cases. Cells, mask groups and shadings hold
// their data apart from the dictionaries that name them; painted under a mark they make the page a picture.

final class RedactSharedDataTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let groupEntries = "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group <</S /Transparency /CS /DeviceGray>>"
    private let paints = "q 100 0 0 100 100 100 cm /Im1 Do Q"
    private let mask = "<</Type /Mask /S /Luminosity /G 7 0 R>>"
    private let axial = "<</ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 1 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1>>>>"
    private let hole = PdfRect(200, 200, 300, 300)

    private func redact(_ document: PdfDocument) throws -> RedactionResult { try RedactionKit.apply(document, [RedactionMark.fromRect(0, hole)]) }

    private func cell(_ resources: String) -> String {
        "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 600 800] /XStep 600 /YStep 800 /Resources <<\(resources)>>"
    }

    private func tiled(_ content: String) throws -> PdfDocument {
        try RedactionKit.page(content, "/Pattern <</P1 6 0 R>> /XObject <</Im1 7 0 R>>") { pdf in
            pdf.stream(6, self.cell("/XObject <</Im1 7 0 R>>"), self.paints)
            pdf.stream(7, self.imageEntries, self.pixels)
        }
    }

    private func assertClean(_ result: RedactionResult, _ word: String) {
        XCTAssertFalse(RedactionKit.holds(result.bytes, word))
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
    }

    func test_pictureOnlyAPatternCellPaintedLeavesTheListWhenThePatternGoes() throws {
        assertClean(try redact(try tiled("/Pattern cs /P1 scn 200 200 50 50 re f")), "ZQXPIXELSDATA")
    }

    func test_pictureOnlyAPatternCellPaintedLeavesTheListWhenTheCellIsEmptied() throws {
        assertClean(try redact(try tiled("/Pattern cs /P1 scn 200 200 50 50 re f 10 10 5 5 re f")), "ZQXPIXELSDATA")
    }

    func test_groupSharedByTwoMasksIsEmptiedWhenOneOfThemMeetsAMark() throws {
        let document = try RedactionKit.page("/A gs 200 200 50 50 re f /B gs 10 10 5 5 re f", "/ExtGState <</A 6 0 R /B 8 0 R>>") { pdf in
            pdf.obj(6, "<</Type /ExtGState /SMask \(self.mask)>>")
            pdf.stream(7, self.groupEntries + " /Resources <</XObject <</Im1 9 0 R>>>>", self.paints)
            pdf.obj(8, "<</Type /ExtGState /SMask \(self.mask)>>")
            pdf.stream(9, self.imageEntries, self.pixels)
        }
        assertClean(try redact(document), "ZQXPIXELSDATA")
    }

    func test_shadingSharedByTwoPatternsGoesWhenOneOfThemMeetsAMark() throws {
        let document = try RedactionKit.page("/Pattern cs /SP1 scn 200 200 50 50 re f /SP2 scn 10 10 5 5 re f", "/Pattern <</SP1 6 0 R /SP2 7 0 R>>") { pdf in
            pdf.obj(6, "<</PatternType 2 /Shading 8 0 R>>")
            pdf.obj(7, "<</PatternType 2 /Shading 8 0 R>>")
            pdf.stream(8, "/ShadingType 4 /ColorSpace /DeviceGray /BitsPerCoordinate 8 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 600 0 800 0 1]", "ZQXMESHSAMPLES")
        }
        assertClean(try redact(document), "ZQXMESHSAMPLES")
    }

    func test_cellThatPaintsAShadingPatternWithAMaskGroupIsEmptied() throws {
        let document = try RedactionKit.page("/Pattern cs /P1 scn 200 200 50 50 re f 10 10 5 5 re f", "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, self.cell("/Pattern <</SP 7 0 R>>"), "/Pattern cs /SP scn 0 0 600 800 re f")
            pdf.obj(7, "<</PatternType 2 /Shading \(self.axial) /ExtGState <</SMask <</Type /Mask /S /Luminosity /G 8 0 R>>>>>>")
            pdf.stream(8, self.groupEntries + " /Resources <</XObject <</Im1 9 0 R>>>>", self.paints)
            pdf.stream(9, self.imageEntries, self.pixels)
        }
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_maskGroupWithoutResourcesTakesThePagesAndIsEmptied() throws {
        let document = try RedactionKit.page("/A gs 200 200 50 50 re f 10 10 5 5 re f", "/ExtGState <</A 7 0 R>> /XObject <</Im1 8 0 R>>") { pdf in
            pdf.stream(6, self.groupEntries, self.paints)
            pdf.obj(7, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 6 0 R>>>>")
            pdf.stream(8, self.imageEntries, self.pixels)
        }
        assertClean(try redact(document), "ZQXPIXELSDATA")
    }
}
