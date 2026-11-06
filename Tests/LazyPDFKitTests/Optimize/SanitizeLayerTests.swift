import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/SanitizeLayerTests.cs: the same cases. The PdfPig text assertion of
// HiddenLayerContentIsCutOutOfEveryStream has no twin; the engine's text is checked above it.

final class SanitizeLayerTests: XCTestCase {
    // Layer 5 is off and layer 6 on; 7 is a membership dictionary that follows 5.
    private let catalog = "/OCProperties <</OCGs [5 0 R 6 0 R] /D <</OFF [5 0 R] /Order [5 0 R 6 0 R]>>>>"

    private func fixture() -> [UInt8] {
        OptimizeKit.build(
            "/OC /L1 BDC 1 0 0 rg 0 0 50 50 re f BT /F1 12 Tf 10 10 Td (HIDDENTEXT) Tj ET EMC " +
            "BT /F1 12 Tf 10 100 Td (VISIBLETEXT) Tj ET " +
            "/OC /L2 BDC BT /F1 12 Tf 10 120 Td (SHOWNLAYER) Tj ET EMC " +
            "/OC /M1 BDC BT /F1 12 Tf 10 140 Td (HIDDENMEMBER) Tj ET EMC " +
            "q /Fm0 Do Q q /Fm1 Do Q q 20 0 0 20 100 100 cm /Im0 Do Q",
            "/Font <</F1 8 0 R>> /Properties <</L1 5 0 R /L2 6 0 R /M1 7 0 R>> /XObject <</Fm0 9 0 R /Fm1 10 0 R /Im0 11 0 R>>",
            { pdf in
                pdf.obj(5, "<</Type /OCG /Name (MARKERLAYER)>>")
                pdf.obj(6, "<</Type /OCG /Name (Shown)>>")
                pdf.obj(7, "<</Type /OCMD /OCGs [5 0 R]>>")
                pdf.obj(8, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
                pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /OC 5 0 R", "BT /F1 12 Tf (HIDDENFORM) Tj ET")
                pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources <</Font <</F1 8 0 R>> /Properties <</L1 5 0 R>>>>",
                           "BT /F1 12 Tf 10 60 Td (INSIDEVISIBLE) Tj ET /OC /L1 BDC BT /F1 12 Tf (INSIDEHIDDEN) Tj ET EMC")
                pdf.stream(11, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /OC 5 0 R", "H")
            }, catalogExtra: catalog)
    }

    func test_hiddenLayerContentIsCutOutOfEveryStream() throws {
        let file = fixture()
        let texts = ["HIDDENTEXT", "HIDDENMEMBER", "HIDDENFORM", "INSIDEHIDDEN", "MARKERLAYER"]
        for text in texts { XCTAssertTrue(try OptimizeKit.everywhere(file, text), text) }
        let document = try PdfDocument.open(file)
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        for text in texts { XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, text), text) }
        let shown = try OptimizeKit.engineText(result.bytes)
        XCTAssertTrue(shown.contains("VISIBLETEXT"), shown)
        XCTAssertTrue(shown.contains("SHOWNLAYER"), shown)
        XCTAssertTrue(shown.contains("INSIDEVISIBLE"), shown)
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .hiddenLayers))
    }

    func test_theVisibleLayerAndItsGroupSurvive() throws {
        let document = try PdfDocument.open(fixture())
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        let after = try PdfDocument.open(result.bytes)
        let layers = PdfLayers.read(after)
        XCTAssertEqual(1, layers.layers.count)
        XCTAssertEqual("Shown", layers.layers.first?.name)
        XCTAssertEqual(true, layers.layers.first?.isOn)
        let operations = ContentParser.parse(after.pages[0].contents())
        XCTAssertEqual(operations.filter { $0.operator == "BDC" || $0.operator == "BMC" }.count, operations.filter { $0.operator == "EMC" }.count)
    }

    func test_hiddenLayersStayWhenNotAsked() throws {
        let document = try PdfDocument.open(fixture())
        let findings = try PdfSanitizer(document).scan()
        XCTAssertEqual(1, SanitizeKit.count(findings, .hiddenLayers))
        let result = try PdfSanitizer(document).run(SanitizeOptions(hiddenLayers: false))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "HIDDENTEXT"))
        XCTAssertEqual(1, SanitizeKit.count(result.kept, .hiddenLayers))
    }

    func test_annotationOnAHiddenLayerGoes() throws {
        let file = OptimizeKit.build("BT /F1 12 Tf (page) Tj ET", "", { pdf in
            pdf.obj(5, "<</Type /OCG /Name (Hidden)>>")
            pdf.obj(6, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /OC 5 0 R /Contents (MARKERNOTE)>>")
            pdf.obj(7, "<</Type /Annot /Subtype /Link /Rect [20 0 30 10] /Contents (kept)>>")
        }, pageExtra: "/Annots [6 0 R 7 0 R]", catalogExtra: "/OCProperties <</OCGs [5 0 R] /D <</BaseState /OFF /ON []>>>>")
        let document = try PdfDocument.open(file)
        let result = try PdfSanitizer(document).run(SanitizeOptions(comments: false))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERNOTE"))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "kept"))
    }
}
