import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactStrictContentTests.cs: the same cases. Content that two viewers may split
// differently is not understood: the page becomes a picture instead of being cut by the parser's reading.

final class RedactStrictContentTests: XCTestCase {
    private let word = "BT /F1 12 Tf 100 100 Td (ZQXSECRET) Tj ET"
    private let near = RedactionMark.fromRect(0, PdfRect(90, 90, 300, 120))

    private func assertFlat(_ content: String, _ resources: String = "") throws {
        try RedactionKit.assertFlattened(try RedactionKit.page(content, resources), [near], "ZQXSECRET")
    }

    func test_strayDelimitersAndOddNumbersMakeThePagePicture() throws {
        let cases = [
            "BT /F1 12 Tf 100 100 Td 300 300 ] Td (ZQXSECRET) Tj ET",
            "BT /F1 12 Tf 100 100 Td 300 300 } Td (ZQXSECRET) Tj ET",
            "BT /F1 12 Tf 100 100 Td 300 300 > Td (ZQXSECRET) Tj ET",
            "BT /F1 12 Tf 100 100 Td 300 300 ) Td (ZQXSECRET) Tj ET",
            "BT /F1 12 Tf 100 100 Td 300 300 { Td (ZQXSECRET) Tj ET",
            "BT /F1 12 Tf 100 100 Td 300-300 Td (ZQXSECRET) Tj ET",
            "BT /F1 12 Tf 100 100 Td 300 300Td (ZQXSECRET) Tj ET",
            "BT /F1 12 Tf 100 100 Td 1.2.3 0 Td (ZQXSECRET) Tj ET",
            "BT /F1 12 Tf 4294967296 0 Td 100 100 Td (ZQXSECRET) Tj ET",
            "BT /F1 12 Tf 1E3 0 Td 100 100 Td (ZQXSECRET) Tj ET",
        ]
        for content in cases { try assertFlat(content) }
    }

    func test_commentsLeftOperandsAndPaintingInsideATextObjectMakeThePagePicture() throws {
        let cases = [
            word + "\n% ZQXSECRET is here\nq Q",
            word + " (ZQXSECRET)",
            word + " [(ZQXSECRET) 1",
            word + " <</Note (ZQXSECRET)",
            "BT /F1 12 Tf 1 0 0 1 100 100 Tm q 1 0 0 1 400 400 Tm Q (ZQXSECRET) Tj ET",
            "BT /F1 12 Tf 100 100 Td 1 0 0 1 300 0 cm (ZQXSECRET) Tj ET",
        ]
        for content in cases { try assertFlat(content) }
    }

    func test_formEndingInAnOperandMakesThePagePicture() throws {
        let document = try RedactionKit.page(word + " /Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800]", "q Q (ZQXSECRET)")
        }
        try RedactionKit.assertFlattened(document, [near], "ZQXSECRET")
    }

    private func stream(_ document: PdfDocument, _ content: String) throws -> PdfReference {
        try document.add(PdfStream(PdfDictionary(), data: Latin1.bytes(content)))
    }

    func test_tokenOpenAtTheEndOfAContentStreamMakesThePagePicture() throws {
        let cases = [("% tail", "1 0 0 1 300 0 cm\n" + word), ("BT /F1 12 Tf 100 100 Td (ZQX", "SECRET) Tj ET"), ("BT /F1 12 Tf 100 100 Td (ZQXSECRET) T", "j ET")]
        for (first, second) in cases {
            let document = try RedactionKit.page("")
            document.pages[0].dictionary["Contents"] = PdfArray([try stream(document, first), try stream(document, second)])
            try RedactionKit.assertFlattened(document, [near], "ZQXSECRET")
        }
    }

    func test_contentStreamThatDoesNotReadMakesThePagePicture() throws {
        let document = try RedactionKit.page("")
        let dictionary = PdfDictionary()
        dictionary["Filter"] = PdfName("BogusDecode")
        let broken = try document.add(PdfStream(dictionary, data: Latin1.bytes("OTHERTEXT")))
        document.pages[0].dictionary["Contents"] = PdfArray([try stream(document, word), broken])
        try RedactionKit.assertFlattened(document, [near], "ZQXSECRET")
    }

    func test_contentStreamsThatEndOnWholeTokensAreStillCut() throws {
        let document = try RedactionKit.page("")
        document.pages[0].dictionary["Contents"] = PdfArray([try stream(document, "BT /F1 12 Tf 100 100 Td [(ZQX)"), try stream(document, "(SECRET)] TJ ET")])
        let result = try PdfRedactor(document).apply([near])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSECRET"))
    }

    func test_patternNameOutsideAPatternSpaceMakesThePagePicture() throws {
        let document = try RedactionKit.page("/P1 scn 100 100 200 200 re f " + word, "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <<>>", "0 0 5 5 re f")
        }
        try RedactionKit.assertFlattened(document, [near], "ZQXSECRET")
    }

    func test_setColourWithAPatternNameMakesThePagePicture() throws {
        let document = try RedactionKit.page("/Pattern cs /P1 sc 100 100 200 200 re f " + word, "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.obj(6, "<</PatternType 2 /Shading <</ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function <</FunctionType 2 /Domain [0 1] /N 1>>>>>>")
        }
        try RedactionKit.assertFlattened(document, [near], "ZQXSECRET")
    }

    func test_fontOfAnUnknownKindMakesThePagePicture() throws {
        let document = try RedactionKit.page("BT /F2 12 Tf 100 100 Td (ZQXSECRET) Tj ET", "/Font <</F2 6 0 R>>") { pdf in
            pdf.obj(6, "<</Type /Font /Subtype /Foo /BaseFont /Helvetica /Encoding /Identity-H /DescendantFonts [7 0 R]>>")
            pdf.obj(7, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /DW 100>>")
        }
        try RedactionKit.assertFlattened(document, [near], "ZQXSECRET")
    }

    func test_textAndTextObjectsInOrderStayText() throws {
        let document = try RedactionKit.page("q 1 0 0 1 0 0 cm " + word + " Q BT /F1 12 Tf 300 300 Td (kept) Tj ET")
        let result = try PdfRedactor(document).apply([near])
        XCTAssertTrue(result.report.flattened.isEmpty)
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "kept")
    }
}
