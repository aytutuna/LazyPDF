import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactPruneTests.cs: the same cases. What is left in the lists of a page after
// a removal: only what the new content names.

final class RedactPruneTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let hole = PdfRect(200, 200, 300, 300)

    private func redact(_ document: PdfDocument, _ mark: PdfRect? = nil) throws -> RedactionResult {
        try RedactionKit.apply(document, [RedactionMark.fromRect(0, mark ?? hole)])
    }

    private func twoPages(_ first: String, _ second: String, _ shared: String) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources 9 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources 9 0 R>>")
        pdf.stream(5, "", first)
        pdf.stream(6, "", second)
        pdf.obj(7, RedactionKit.helvetica)
        pdf.obj(9, shared)
        return try PdfDocument.open(pdf.finish())
    }

    func test_patternFillWithAPictureInItsCellMakesThePagePicture() throws {
        let document = try RedactionKit.page("/Pattern cs /P1 scn 150 150 200 200 re f", "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 50 50] /XStep 50 /YStep 50 /Resources <</XObject <</Im1 7 0 R>>>>", "q 50 0 0 50 0 0 cm /Im1 Do Q")
            pdf.stream(7, self.imageEntries, self.pixels)
        }
        try RedactionKit.assertFlattened(document, hole, "ZQXPIXELSDATA")
    }

    func test_patternWithAPictureIsEmptiedForTheOtherPaintsToo() throws {
        let document = try RedactionKit.page("/Pattern cs /P1 scn 150 150 200 200 re f 400 400 50 50 re f", "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 50 50] /XStep 50 /YStep 50 /Resources <</XObject <</Im1 7 0 R>>>>", "q 50 0 0 50 0 0 cm /Im1 Do Q")
            pdf.stream(7, self.imageEntries, self.pixels)
        }
        let result = try redact(document)
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_softMaskOfARemovedShapeIsDropped() throws {
        let document = try RedactionKit.page("/GS1 gs 210 210 m 280 210 l 250 280 l f", "/ExtGState <</GS1 6 0 R>>") { pdf in
            pdf.obj(6, "<</Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 7 0 R >> >>")
            pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group << /S /Transparency /CS /DeviceGray >> /Resources <</XObject <</Im1 8 0 R>>>>", "q 100 0 0 100 100 100 cm /Im1 Do Q")
            pdf.stream(8, self.imageEntries, self.pixels)
        }
        let result = try redact(document)
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_meshShadingUnderTheMarkIsRemovedWithItsData() throws {
        let document = try RedactionKit.page("/Sh1 sh", "/Shading <</Sh1 6 0 R>>") { pdf in
            pdf.stream(6, "/ShadingType 4 /ColorSpace /DeviceGray /BitsPerCoordinate 8 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 600 0 800 0 1]", "ZQXMESHDATAZQXMESHDATA")
        }
        let result = try redact(document)
        let output = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMESHDATA"))
        XCTAssertFalse(try RedactionKit.latin(output).contains("Sh1 sh"))
        XCTAssertEqual(result.report.paths, 1)
    }

    private func twoFonts(_ content: String) throws -> PdfDocument {
        try ContentTestPdf.page(content, "/Font <</F1 5 0 R /F2 6 0 R>>") { pdf in
            pdf.obj(5, RedactionKit.helvetica)
            pdf.obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /ZQXSubset /FirstChar 65 /LastChar 66 /Widths [500 500] /ToUnicode 7 0 R>>")
            pdf.stream(7, "", "ZQXTOUNICODE")
        }
    }

    func test_fontOnlyTheRemovedTextUsedIsDropped() throws {
        let document = try twoFonts("BT /F1 12 Tf 50 100 Td (visible) Tj /F2 12 Tf 0 400 Td (AB) Tj ET")
        let result = try redact(document, PdfRect(40, 490, 100, 520))
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "visible")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXTOUNICODE"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSubset"))
    }

    func test_fontStillShowingTextElsewhereStays() throws {
        let document = try twoFonts("BT /F2 12 Tf 50 100 Td (AB) Tj 0 400 Td (AB) Tj ET")
        let result = try redact(document, PdfRect(40, 490, 100, 520))
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "AB")
        XCTAssertTrue(RedactionKit.holds(result.bytes, "ZQXTOUNICODE"))
    }

    func test_pictureListedByAnotherFormIsNotLeftBehind() throws {
        let document = try RedactionKit.page("/Fm1 Do /Fm2 Do", "/XObject <</Fm1 6 0 R /Fm2 7 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources 9 0 R", "q 160 0 0 160 100 100 cm /Im0 Do Q")
            pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources 9 0 R", "0 g 0 0 1 1 re f")
            pdf.stream(8, self.imageEntries, self.pixels)
            pdf.obj(9, "<</XObject <</Im0 8 0 R>>>>")
        }
        let result = try redact(document, PdfRect(100, 220, 140, 260))
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, pixels))
        XCTAssertEqual(result.report.images, 1)
    }

    func test_propertyListOfARewrittenSequenceDoesNotStayInASharedResourceList() throws {
        let shared = "<</Font <</F1 7 0 R>> /Properties <</P1 << /MCID 0 /ActualText (ZQXACTUALTEXT) >> >> >>"
        let document = try twoPages("/Span /P1 BDC BT /F1 12 Tf 50 700 Td (secretword) Tj ET EMC", "BT /F1 12 Tf 50 700 Td (other) Tj ET", shared)
        let result = try redact(document, PdfRect(40, 690, 200, 720))
        let output = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXACTUALTEXT"))
        XCTAssertEqual(RedactionKit.text(output, 1), "other")
    }
}
