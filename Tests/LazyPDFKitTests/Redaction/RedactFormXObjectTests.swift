import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactFormXObjectTests.cs: the same cases.

final class RedactFormXObjectTests: XCTestCase {
    private let form = "/Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources <</Font <</F1 5 0 R>>>>"

    // A form drawing the marker once, painted twice: at y 100 and y 500.
    private func twoPlacements() throws -> PdfDocument {
        try RedactionKit.page("q 1 0 0 1 50 100 cm /Fm1 Do Q q 1 0 0 1 50 500 cm /Fm1 Do Q", "/XObject <</Fm1 6 0 R>>") { pdf in
            pdf.stream(6, self.form, "BT /F1 12 Tf 10 50 Td (ZQXMARKER) Tj ET")
        }
    }

    // The original of a form stays for a use that has nothing cut out of it, and holds what was cut from the other, so the page becomes a picture.
    func test_formUsedTwiceWithAMarkOnOneUseMakesThePagePicture() throws {
        let document = try twoPlacements()
        try RedactionKit.assertFlattened(document, PdfRect(40, 140, 200, 170), "ZQXMARKER")
    }

    func test_formUsedTwiceAndMarkedOnBothUsesIsCutOnEachCopy() throws {
        let document = try twoPlacements()
        let marks = [PdfRect(40, 140, 200, 170), PdfRect(40, 540, 200, 570)].map { RedactionMark.fromRect(0, $0) }
        let result = try PdfRedactor(document).apply(marks)
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertEqual(result.report.glyphs, 18)
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMARKER"))
    }

    func test_formUsedOnTwoPagesKeepsItsTextOnTheOther() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</XObject <</Fm1 7 0 R>>>>>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</XObject <</Fm1 7 0 R>>>>>>")
        pdf.stream(5, "", "q 1 0 0 1 50 100 cm /Fm1 Do Q")
        pdf.obj(6, ContentTestPdf.helvetica)
        pdf.stream(7, form.replacingOccurrences(of: "5 0 R", with: "6 0 R"), "BT /F1 12 Tf 10 50 Td (ZQXMARKER) Tj ET")
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(40, 140, 200, 170))])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output, 0), "")
        XCTAssertEqual(RedactionKit.text(output, 1), "ZQXMARKER")
    }

    private func nested(_ content: String) throws -> PdfDocument {
        try RedactionKit.page(content, "/XObject <</Outer 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources <</Font <</F1 5 0 R>> /XObject <</Inner 7 0 R>>>>",
                       "q 1 0 0 1 0 20 cm /Inner Do Q BT /F1 12 Tf 10 5 Td (outer) Tj ET")
            pdf.stream(7, self.form, "BT /F1 12 Tf 10 30 Td (ZQXMARKER) Tj ET")
        }
    }

    func test_nestedFormsAreCopiedAlongTheChain() throws {
        let document = try nested("q 1 0 0 1 50 100 cm /Outer Do Q")
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(40, 150, 300, 185))])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "outer")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMARKER"))
    }

    func test_nestedFormsUsedTwiceWithAMarkOnOneUseMakeThePagePicture() throws {
        let document = try nested("q 1 0 0 1 50 100 cm /Outer Do Q q 1 0 0 1 50 500 cm /Outer Do Q")
        try RedactionKit.assertFlattened(document, PdfRect(40, 150, 300, 185), "ZQXMARKER")
    }

    func test_imageInsideAFormIsCutOnACopyOfTheForm() throws {
        let data = [UInt8](repeating: 7, count: 16)
        let document = try RedactionKit.page("q 1 0 0 1 50 100 cm /Fm1 Do Q", "/XObject <</Fm1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources <</XObject <</Im 7 0 R>>>>", "q 100 0 0 100 0 0 cm /Im Do Q")
            pdf.stream(7, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8", data)
        }
        // The image is 100 points square at 50..150 over 100..200: its top left pixel.
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(50, 175, 70, 200))])
        let output = try RedactionKit.open(result)
        let images = RedactionKit.images(output)
        XCTAssertEqual(images.count, 1)
        let samples = try output.data(try XCTUnwrap(images.first?.stream))
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 7)
    }

    func test_formWithoutResourcesOfItsOwnStillWorks() throws {
        let document = try RedactionKit.page("q 1 0 0 1 50 100 cm /Fm1 Do Q", "/XObject <</Fm1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 300 100]", "BT /F1 12 Tf 10 50 Td (ZQXMARKER) Tj ET")
        }
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(40, 140, 200, 170))])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "")
    }

    func test_formThatMissesTheMarkIsNotCopied() throws {
        let document = try twoPlacements()
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(400, 400, 450, 450))])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.glyphs(output).count, 18)
        let forms = output.objectNumbers.compactMap { output.get($0) as? PdfStream }.filter { output.name($0.dictionary, "Subtype") == "Form" }
        XCTAssertEqual(forms.count, 1)
    }

    func test_actualTextAndAltOfTheMarkedContentGoWithTheText() throws {
        let content = "/Span <</ActualText (ZQXMARKER secret) /MCID 0>> BDC BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET EMC "
            + "/Figure /P1 BDC BT /F1 12 Tf 50 600 Td (ZQXMARKER) Tj ET EMC "
            + "/Span <</ActualText (kept text)>> BDC BT /F1 12 Tf 50 500 Td (kept) Tj ET EMC"
        let document = try RedactionKit.page(content, "/Properties <</P1 <</Alt (ZQXMARKER figure) /MCID 1>>>>")
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXMARKER"))
        let output = try RedactionKit.open(result)
        let after = try RedactionKit.latin(output)
        XCTAssertFalse(after.contains("ZQXMARKER"))
        XCTAssertTrue(after.contains("kept text"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMARKER"))
        XCTAssertTrue(after.contains("/MCID 0"))
        XCTAssertEqual(RedactionKit.text(output), "kept")
    }
}
