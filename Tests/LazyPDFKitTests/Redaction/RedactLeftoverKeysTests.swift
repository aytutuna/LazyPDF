import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactLeftoverKeysTests.cs: the same cases. Descriptions, attachments and page
// keys that stay behind when their content is cut, and the picture a flattened page becomes.

final class RedactLeftoverKeysTests: XCTestCase {
    private let over = RedactionFiles.over

    func test_descriptionsOfCutTextGoWhateverHoldsThem() throws {
        let cases = [("/Note /P0 DP /Span <</MCID 0>> BDC", "/Properties <</P0 6 0 R>>"), ("/Span <</MCID 0 /X <</Alt (ZQXDESC)>>>> BDC", ""),
                     ("/Span <</MCID 0 /Alt (ZQXDESC)>> BDC", "")]
        for (open, resources) in cases {
            let document = try RedactionFiles.open(open + " " + RedactionFiles.word + " EMC", resources, { pdf in pdf.obj(6, "<</ActualText (ZQXDESC)>>") })
            let result = try RedactionFiles.apply(document, RedactionMark.fromRect(0, over))
            RedactionFiles.gone(result, "ZQXDESC", "ZQXSECRET")
        }
    }

    private func tagged(_ element: String, _ more: ((TestPdf) -> Void)? = nil) throws -> PdfDocument {
        try RedactionFiles.open("/Figure <</MCID 0>> BDC " + RedactionFiles.picture + " EMC /P <</MCID 1>> BDC BT /F1 12 Tf 400 600 Td (kept) Tj ET EMC",
                                "/XObject <</Im1 6 0 R>>", { pdf in
            RedactionFiles.image(pdf, 6)
            pdf.obj(10, "<</Type /StructTreeRoot /K 11 0 R>>")
            pdf.obj(11, element)
            more?(pdf)
        }, pageExtra: "/StructParents 0", catalogExtra: "/StructTreeRoot 10 0 R")
    }

    func test_elementWithoutAPageLosesItsDescription() throws {
        let document = try tagged("<</Type /StructElem /S /Figure /P 10 0 R /Alt (ZQXALTTEXT) /K 0>>")
        RedactionFiles.gone(try RedactionFiles.apply(document, RedactionMark.fromRect(0, PdfRect(90, 90, 250, 250))), "ZQXALTTEXT")
    }

    func test_elementThatStaysLosesItsAssociatedFiles() throws {
        let document = try tagged("<</Type /StructElem /S /Figure /P 10 0 R /Pg 30 0 R /K [0 1] /AF [12 0 R]>>") { pdf in
            pdf.obj(12, "<</Type /Filespec /F (s.txt) /EF <</F 13 0 R>>>>")
            pdf.stream(13, "/Type /EmbeddedFile", "ZQXSOURCEDATA")
        }
        RedactionFiles.gone(try RedactionFiles.apply(document, RedactionMark.fromRect(0, PdfRect(90, 90, 250, 250))), "ZQXSOURCEDATA")
    }

    func test_privatePageKeysAreNotKept() throws {
        let document = try RedactionFiles.open(RedactionFiles.word, "", { pdf in pdf.stream(6, "", "ZQXTHUMB") }, pageExtra: "/Private <</Note (ZQXNOTE)>> /Thumb 6 0 R")
        RedactionFiles.gone(try RedactionFiles.apply(document, RedactionMark.fromRect(0, over)), "ZQXNOTE", "ZQXTHUMB")
    }

    func test_flatteningOnePageLeavesTheWidgetOfAnUnmarkedPageAndItsField() throws {
        let document = try RedactionFiles.open(["% not whole\n" + RedactionFiles.word, "BT ET"], "", { pdf in
            pdf.obj(10, "<</FT /Tx /T (date) /V (Monday) /Kids [11 0 R 12 0 R]>>")
            pdf.obj(11, "<</Type /Annot /Subtype /Widget /Parent 10 0 R /Rect [400 600 450 620] /P 30 0 R>>")
            pdf.obj(12, "<</Type /Annot /Subtype /Widget /Parent 10 0 R /Rect [400 600 450 620] /P 32 0 R>>")
        }, pageExtras: ["/Annots [11 0 R]", "/Annots [12 0 R]"], catalogExtra: "/AcroForm <</Fields [10 0 R]>>")
        let result = try RedactionFiles.apply(document, RedactionMark.fromRect(0, over))
        XCTAssertTrue(result.report.flattened.contains(0))
        let output = try RedactionKit.reopen(result.bytes)
        XCTAssertEqual(PdfAnnotations.read(output, output.pages[1]).count, 1)
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
    }

    private final class SquareRenderer: PageRenderer {
        func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { PdfRgbaImage(100, 100, [UInt8](repeating: 0, count: 100 * 100 * 4)) }
    }

    func test_pictureDrawnInAnotherShapeThanThePageIsRefused() throws {
        let document = try RedactionFiles.open("% not whole\n" + RedactionFiles.word)
        var options = RedactionOptions()
        options.renderer = SquareRenderer()
        options.flattenDpi = 24
        XCTAssertThrowsError(try PdfRedactor(document).apply([RedactionMark.fromRect(0, over)], options)) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, RedactionText.notDrawn(0))
        }
    }
}
