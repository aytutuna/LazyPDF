import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactPatternMaskTests.cs: the same cases. Cells of patterns and groups of soft
// masks are not cut by the marks: with pictures or text they make the page a picture, and fonts nothing shows any more leave
// with the text.

final class RedactPatternMaskTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let group = "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group << /S /Transparency /CS /DeviceGray >> /Resources <</XObject <</Im1 8 0 R>> /Font <</F1 5 0 R>>>>"
    private let subset = "<</Type /Font /Subtype /Type1 /BaseFont /ZQXSubset /FirstChar 65 /LastChar 66 /Widths [500 500] /ToUnicode 8 0 R>>"
    private let hole = PdfRect(200, 200, 300, 300)

    private func redact(_ document: PdfDocument) throws -> RedactionResult { try RedactionKit.apply(document, [RedactionMark.fromRect(0, hole)]) }

    private func masked(_ content: String) throws -> PdfDocument {
        try RedactionKit.page(content, "/ExtGState <</GS1 6 0 R>>") { pdf in
            pdf.obj(6, "<</Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 7 0 R >> >>")
            pdf.stream(7, self.group, "q 100 0 0 100 100 100 cm /Im1 Do Q BT /F1 12 Tf 200 200 Td (ZQXGROUPTEXT) Tj ET")
            pdf.stream(8, self.imageEntries, self.pixels)
        }
    }

    func test_maskedFillThatMeetsAMarkMakesThePagePicture() throws {
        let document = try masked("/GS1 gs 0 0 600 800 re f")
        try RedactionKit.assertFlattened(document, hole, "ZQXPIXELSDATA", "ZQXGROUPTEXT")
    }

    func test_maskAlsoUsedElsewhereIsEmptiedNotKeptWhole() throws {
        let document = try masked("/GS1 gs 0 0 600 800 re f 10 10 5 5 re f")
        let result = try redact(document)
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXGROUPTEXT"))
    }

    func test_patternCellAlsoUsedElsewhereIsEmptiedNotKeptWhole() throws {
        let document = try RedactionKit.page("/Pattern cs /P1 scn 0 0 600 800 re f 10 10 5 5 re f", "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 600 800] /XStep 600 /YStep 800 /Resources <</XObject <</Im1 7 0 R>>>>", "q 600 0 0 800 0 0 cm /Im1 Do Q")
            pdf.stream(7, self.imageEntries, self.pixels)
        }
        let result = try redact(document)
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_patternFilledTextKeepsNoCellTextWhenOneWordIsOutsideTheMark() throws {
        let document = try RedactionKit.page("/Pattern cs /P1 scn BT /F1 12 Tf 210 250 Td (inside) Tj 0 300 Td (outside) Tj ET", "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 50 50] /XStep 50 /YStep 50 /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 5 5 Td (ZQXCELLTEXT) Tj ET")
        }
        let result = try redact(document)
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXCELLTEXT"))
    }

    func test_patternOfPlainShapesStaysForOtherUses() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 150 150 Td (ZQXWORD) Tj ET /Pattern cs /P1 scn 400 400 50 50 re f", "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <<>>", "0 0 5 5 re f")
        }
        let result = try PdfRedactor(document).apply([try RedactionKit.markOf(document, 0, "ZQXWORD")])
        XCTAssertTrue(result.report.flattened.isEmpty)
        let output = try RedactionKit.open(result)
        let cell = output.dict(output.dict(output.pages[0].dictionary, "Resources"), "Pattern")?["P1"]
        let stream = try XCTUnwrap(output.resolve(cell) as? PdfStream)
        XCTAssertTrue(Latin1.string(try output.data(stream)).contains("5 5 re"))
    }

    func test_axialShadingPatternUnderTheMarkIsRemovedFromThatUse() throws {
        let document = try RedactionKit.page("/Pattern cs /P1 scn 150 150 200 200 re f", "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.obj(6, "<</PatternType 2 /Shading <</ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function <</FunctionType 2 /Domain [0 1] /N 1>>>>>>")
        }
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, hole)])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertEqual(result.report.paths, 1)
    }

    func test_meshShadingPatternUnderTheMarkMakesThePagePicture() throws {
        let document = try RedactionKit.page("/Pattern cs /P1 scn 150 150 200 200 re f", "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.obj(6, "<</PatternType 2 /Shading 7 0 R>>")
            pdf.stream(7, "/ShadingType 4 /ColorSpace /DeviceGray /BitsPerCoordinate 8 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 255 0 255 0 1]", "ZQXMESHDATA")
        }
        try RedactionKit.assertFlattened(document, hole, "ZQXMESHDATA")
    }

    func test_fontStillUsedByAMaskGroupKeepsItsResource() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (secret) Tj ET /GS1 gs 400 400 50 50 re f", "/ExtGState <</GS1 6 0 R>>") { pdf in
            pdf.obj(6, "<</Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 7 0 R >> >>")
            pdf.stream(7, self.group, "BT /F1 12 Tf 410 410 Td (mask) Tj ET")
            pdf.stream(8, self.imageEntries, self.pixels)
        }
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, PdfRect(90, 690, 200, 720))])
        let output = try RedactionKit.open(result)
        let groups = output.objectNumbers.compactMap { output.get($0) as? PdfStream }.filter { output.dict($0.dictionary, "Group") != nil }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(output.dict(output.dict(groups[0].dictionary, "Resources"), "Font")?.containsKey("F1"), true)
    }

    func test_fontListedInTheFormDefaultsIsDropped() throws {
        let document = try RedactionKit.page("BT /F2 12 Tf 50 100 Td (AB) Tj ET", "/Font <</F1 5 0 R /F2 6 0 R>>") { pdf in
            pdf.obj(5, RedactionKit.helvetica)
            pdf.obj(6, self.subset)
            pdf.stream(8, "", "ZQXTOUNICODE")
        }
        _ = try PdfForm.read(document).addField(FieldSpec(.text, "f", 0, PdfRect(300, 400, 400, 420)))
        let form = try XCTUnwrap(document.dict(document.catalog, "AcroForm"))
        let fonts = PdfDictionary()
        fonts["F2"] = PdfReference(6, 0)
        let defaults = PdfDictionary()
        defaults["Font"] = fonts
        form["DR"] = defaults
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, PdfRect(40, 90, 100, 120))])
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXTOUNICODE"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSubset"))
    }

    func test_fontSelectedByAGraphicsStateMakesThePagePicture() throws {
        let document = try ContentTestPdf.page("/GS1 gs BT 50 100 Td (AB) Tj ET", "/ExtGState <</GS1 7 0 R>>") { pdf in
            pdf.obj(6, self.subset)
            pdf.obj(7, "<</Type /ExtGState /Font [6 0 R 12]>>")
            pdf.stream(8, "", "ZQXTOUNICODE")
        }
        try RedactionKit.assertFlattened(document, PdfRect(40, 90, 100, 120), "ZQXTOUNICODE", "ZQXSubset")
    }

    func test_fontOfTheRemovedTextLeavesTheResourcesWithItsSelection() throws {
        let document = try ContentTestPdf.page("BT /F1 12 Tf 50 700 Td (visible) Tj /F2 12 Tf 0 -200 Td (AB) Tj ET", "/Font <</F1 5 0 R /F2 6 0 R>>") { pdf in
            pdf.obj(5, RedactionKit.helvetica)
            pdf.obj(6, self.subset)
            pdf.stream(8, "", "ZQXTOUNICODE")
        }
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, PdfRect(40, 490, 100, 520))])
        let output = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSubset"))
        XCTAssertNotEqual(output.dict(output.dict(output.pages[0].dictionary, "Resources"), "Font")?.containsKey("F2"), true)
    }
}
