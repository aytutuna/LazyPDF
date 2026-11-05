import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextAnnotationOptionTests.cs: the same cases. The one-page form is
// IntegrationFiles.Form(1) of the C#. The last case cannot catch the InvalidOperationException the C# raises, because
// it is a precondition in Swift, so only the flag and the message are checked.

final class TextAnnotationOptionTests: TextTestCase {
    private func formFile() -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 4 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [10 0 R] /Count 1 /MediaBox [0 0 400 600]>>")
        pdf.obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.obj(4, "<</Fields [200 0 R 399 0 R] /DA (/Helv 11 Tf 0 g) /DR <</Font <</Helv 3 0 R>>>>>>")
        pdf.obj(10, "<</Type /Page /Parent 2 0 R /Contents 100 0 R /Resources <</Font <</F1 3 0 R /Helv 3 0 R>>>> /Annots [200 0 R 399 0 R]>>")
        pdf.stream(100, "", "BT /F1 14 Tf 40 500 Td (Page 1 body text) Tj ET")
        pdf.obj(200, "<</Type /Annot /Subtype /Widget /FT /Tx /T (f1) /Rect [40 40 240 60] /F 4 /P 10 0 R /MK <</BC [0]>>>>")
        pdf.obj(399, "<</Type /Annot /Subtype /Widget /FT /Btn /T (agree) /Rect [40 100 54 114] /F 4 /P 10 0 R /AS /Off /MK <</BC [0] /CA (4)>>>>")
        return pdf.finish()
    }

    private func annotated() throws -> PdfDocument {
        let document = try PdfDocument.open(formFile())
        try PdfAnnotationWriter(document).addFreeText(document.pages[0], PdfRect(40, 300, 240, 340), "comment text")
        try PdfForm.read(document).setValue("f1", "typed value")
        return try PdfDocument.open(document.saveRewrite())
    }

    func test_pageTextLeavesAnnotationsAndFieldsOutByDefault() throws {
        let document = try annotated()
        let text = TextPage.create(document, document.pages[0]).text
        XCTAssertTrue(text.contains("Page 1 body text"))
        XCTAssertFalse(text.contains("comment"))
        XCTAssertFalse(text.contains("typed"))
    }

    func test_theOptionAddsTheirTextAtTheirPlaces() throws {
        let document = try annotated()
        let page = TextPage.create(document, document.pages[0], TextPageOptions(includeAnnotations: true))
        XCTAssertTrue(page.text.contains("Page 1 body text"))
        XCTAssertTrue(page.text.contains("comment text"))
        XCTAssertTrue(page.text.contains("typed value"))
        let field = try XCTUnwrap(page.words.first { $0.text == "typed" })
        XCTAssertTrue(field.bounds.left >= 40 && field.bounds.left <= 240)
        XCTAssertTrue(field.bounds.bottom >= 38 && field.bounds.bottom <= 62)
    }

    func test_aHiddenAnnotationAddsNothing() throws {
        let document = try PdfDocument.open(formFile())
        let note = try PdfAnnotationWriter(document).addFreeText(document.pages[0], PdfRect(40, 300, 240, 340), "secret remark")
        note.dictionary["F"] = PdfNumber(2)
        let page = TextPage.create(document, document.pages[0], TextPageOptions(includeAnnotations: true))
        XCTAssertFalse(page.text.contains("secret"))
    }

    func test_anAppearanceThatRunsOutOfOperationsMarksThePageTruncated() throws {
        // 220 x 220 x 220 operations, past the interpreter's 10,000,000.
        func repeated(_ op: String) -> String { String(repeating: op, count: 220) }
        let document = try TextTestPdf.page(TextTestPdf.line(100, 700, "body"), "/Font <</F1 5 0 R>>", "/Annots [8 0 R]") { pdf in
            TextTestPdf.font(pdf, 5)
            pdf.obj(8, "<</Type /Annot /Subtype /Stamp /Rect [0 0 100 100] /AP <</N 9 0 R>>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <</XObject <</B 10 0 R>>>>", repeated("/B Do "))
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <</XObject <</C 11 0 R>>>>", repeated("/C Do "))
            pdf.stream(11, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", repeated("n "))
        }
        XCTAssertFalse(TextPage.create(document, document.pages[0]).isTruncated)
        XCTAssertTrue(TextPage.create(document, document.pages[0], TextPageOptions(includeAnnotations: true)).isTruncated)
    }

    func test_textWithAnnotationsIsRefusedWhereOperatorIndexesAreUsed() throws {
        let document = try annotated()
        let plain = TextPage.create(document, document.pages[0])
        let shown = TextPage.create(document, document.pages[0], TextPageOptions(includeAnnotations: true))

        XCTAssertFalse(plain.includesAnnotations)
        plain.requirePageContent()
        XCTAssertTrue(shown.includesAnnotations)
        XCTAssertTrue(TextPageText.annotationsIncluded.hasPrefix("This text includes annotation text"))
    }
}
