import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactUnderstoodTests.cs: the same cases. A page is redacted as text only when
// it is understood in full; every construct outside the list makes it a picture.

final class RedactUnderstoodTests: XCTestCase {
    private let word = "BT /F1 12 Tf 100 100 Td (ZQXWORD) Tj ET"
    private let near = PdfRect(90, 90, 200, 120)

    func test_strayOperatorsOperandsOfTheWrongKindAndUnbalancedRestoresMakeThePagePicture() throws {
        let cases = [
            "foo " + word, "BX " + word + " EX", "BT /F1 12 Tf (x) 100 Td (ZQXWORD) Tj ET", "BT /F1 12 Tf 1 100 100 Td (ZQXWORD) Tj ET",
            "BT 12 /F1 Tf 100 100 Td (ZQXWORD) Tj ET", "BT /F1 12 Tf 100 100 Td (ZQXWORD) 5 Tj ET", "BT /F1 12 Tf 100 100 Td [(ZQXWORD) /x] TJ ET",
            "1 2 " + word, "Q " + word, "q q Q Q Q " + word,
        ]
        for content in cases {
            let document = try RedactionKit.page(content)
            try RedactionKit.assertFlattened(document, near, "ZQXWORD")
        }
    }

    func test_xObjectOfAnyKindButImageAndFormMakesThePagePicture() throws {
        let document = try RedactionKit.page("/X1 Do " + word, "/XObject <</X1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /PS", "ZQXPOSTSCRIPT")
        }
        try RedactionKit.assertFlattened(document, near, "ZQXWORD", "ZQXPOSTSCRIPT")
    }

    func test_inlineImageWhoseLengthDoesNotMatchItsDimensionsMakesThePagePicture() throws {
        let cases = [
            "q BI /W 2 /H 2 /BPC 8 /CS /G ID abcdefghij EI Q ", "q BI /W 2 /H 2 /BPC 8 /CS /Cs9 ID abcd EI Q ", "q BI /W 2 /H 2 /CS /G ID abcd EI Q ",
            "q BI /W 2 /H 1 /BPC 8 /CS /RGB /F /AHx ID 000000000000> EI Q ", "q BI /W 1 /H 4 /BPC 8 /CS /G /F [] ID abcd EI Q ",
            "q BI /W 1 /H 4 /Width 40 /BPC 8 /CS /G ID abcd EI Q ", "q BI /W 1 /H 4 /BPC 8 /CS /G /Note (ZQXWORD) ID abcd EI Q ",
            "q BI /W 1 /H 4 /BPC 8 /CS /G BT /F1 12 Tf 100 100 Td (ZQXWORD) Tj ET ID abcd EI Q ",
        ]
        for image in cases {
            let document = try RedactionKit.page(image + word)
            try RedactionKit.assertFlattened(document, near, "ZQXWORD")
        }
    }

    func test_inlineImageWithItsEndInPlaceKeepsThePageAsText() throws {
        let cases = ["q BI /W 2 /H 2 /BPC 8 /CS /G ID abcd EI Q ", "q BI /W 8 /H 2 /IM true ID ab EI Q ", "q BI /W 2 /H 1 /BPC 8 /CS [/I /RGB 1 <000000ffffff>] ID ab EI Q "]
        for image in cases {
            let document = try RedactionKit.page(image + word)
            let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, near)])
            XCTAssertTrue(result.report.flattened.isEmpty, image)
            XCTAssertEqual(result.report.glyphs, 7, image)
            XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXWORD"), image)
        }
    }

    func test_nameFoundOnlyInAnEnclosingListMakesThePagePicture() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</ProcSet [/PDF]>>", self.word)
        }
        try RedactionKit.assertFlattened(document, near, "ZQXWORD")
    }

    func test_formWithNoResourcesOfItsOwnTakesTheOnesItIsPaintedFrom() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800]", self.word)
        }
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, near)])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXWORD"))
    }

    func test_softMaskThatMeetsAMarkMakesThePagePictureAndOneThatDoesNotDoesNot() throws {
        let state = "/ExtGState <</G 6 0 R>>"
        let objects: (TestPdf) -> Void = { pdf in
            pdf.obj(6, "<</Type /ExtGState /SMask <</Type /Mask /S /Alpha /G 7 0 R>>>>")
            pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group <</S /Transparency>>", "0 0 600 800 re f")
        }
        let meets = try RedactionKit.page("/G gs 80 80 200 80 re f " + word, state, objects)
        try RedactionKit.assertFlattened(meets, near, "ZQXWORD")
        let clear = try RedactionKit.page("q /G gs 300 300 100 100 re f Q " + word, state, objects)
        let result = try PdfRedactor(clear).apply([RedactionMark.fromRect(0, near)])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXWORD"))
    }

    func test_optionalContentUnderAMarkMakesThePagePictureAndOneElsewhereDoesNot() throws {
        let layer = "/Properties <</MC0 <</Type /OCG /Name (Layer)>>>>"
        let under = try RedactionKit.page("/OC /MC0 BDC " + word + " EMC", layer)
        try RedactionKit.assertFlattened(under, near, "ZQXWORD")
        let elsewhere = try RedactionKit.page("/OC /MC0 BDC BT /F1 12 Tf 300 300 Td (other) Tj ET EMC " + word, layer)
        let result = try PdfRedactor(elsewhere).apply([RedactionMark.fromRect(0, near)])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXWORD"))
    }

    func test_ordinaryPageWithShapesImagesFormsAndMarkedContentStaysText() throws {
        let document = try RedactionKit.page("q 0.5 g 300 300 100 100 re f Q /Fm Do /Span <</MCID 0>> BDC " + word + " EMC q 50 0 0 50 400 400 cm /Im1 Do Q BT /F1 12 Tf 100 500 Td [(kept) -20 (text)] TJ ET",
            "/XObject <</Fm 6 0 R /Im1 7 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 300 600 Td (inside) Tj ET")
            pdf.stream(7, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", "a")
        }
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, near)])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertEqual(result.report.glyphs, 7)
        let output = try RedactionKit.open(result)
        XCTAssertTrue(RedactionKit.text(output).contains("inside"))
    }

    func test_verifyReportsAPageThatIsNotUnderstood() throws {
        let document = try RedactionKit.page("foo " + word)
        let problems = PdfRedactor.verify(try document.saveRewrite(), [RedactionMark.fromRect(0, PdfRect(300, 300, 400, 400))], []).problems
        XCTAssertEqual(problems, [RedactionText.notFollowed(0)])
    }

    func test_contentOfAPageWithoutMarksIsNotJudged() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>>>>>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>>>>>>")
        pdf.stream(5, "", word)
        pdf.stream(6, "", "foo BT /F1 12 Tf 100 100 Td (ZQXOTHER) Tj ET")
        pdf.obj(7, RedactionKit.helvetica)
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXWORD"))
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertTrue(RedactionKit.holds(result.bytes, "ZQXOTHER"))
    }
}
