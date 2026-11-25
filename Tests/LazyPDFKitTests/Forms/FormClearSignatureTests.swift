import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormClearSignatureTests.cs: the same cases.

final class FormClearSignatureTests: XCTestCase {
    private func signed(certified: Bool = false) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R 11 0 R] /SigFlags 3>>" + (certified ? " /Perms <</DocMDP 12 0 R>>" : "") + ">>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R]>>")
        pdf.obj(10, "<</Type /Annot /Subtype /Widget /FT /Sig /T (s) /V 12 0 R /AP <</N 13 0 R>> /Rect [0 0 100 20] /P 3 0 R>>")
        pdf.obj(11, "<</Type /Annot /Subtype /Widget /FT /Sig /T (empty) /Rect [0 100 100 120] /P 3 0 R>>")
        pdf.obj(12, "<</Type /Sig /Filter /Adobe.PPKLite>>")
        pdf.stream(13, "/Type /XObject /Subtype /Form /BBox [0 0 100 20]", "0 g")
        return try PdfDocument.open(pdf.finish())
    }

    func test_clearingLeavesAnEmptyFieldWithoutItsAppearance() throws {
        let form = PdfForm.read(try signed())

        try form.clearSignature(try XCTUnwrap(form.find("s")))

        let field = try XCTUnwrap(form.find("s"))
        XCTAssertFalse(field.isSigned)
        XCTAssertFalse(field.dictionary.containsKey("AP"))
        XCTAssertEqual(field.kind, .signature)
    }

    func test_theClearedFieldIsSavedAsAnIncrementalUpdate() throws {
        let doc = try signed()
        let original = try doc.saveIncremental()
        let form = PdfForm.read(doc)
        try form.clearSignature(try XCTUnwrap(form.find("s")))

        let saved = try doc.saveIncremental()

        XCTAssertGreaterThan(saved.count, original.count)
        XCTAssertEqual(Array(saved[..<original.count]), original)
        XCTAssertFalse(try XCTUnwrap(PdfForm.read(try PdfDocument.open(saved)).find("s")).isSigned)
    }

    func test_aCertificationThatRestedOnTheSignatureGoes() throws {
        let doc = try signed(certified: true)
        let form = PdfForm.read(doc)

        try form.clearSignature(try XCTUnwrap(form.find("s")))

        XCTAssertFalse(doc.catalog.containsKey("Perms"))
    }

    func test_aFieldThatIsNotSignedIsRefused() throws {
        let form = PdfForm.read(try signed())

        XCTAssertThrowsError(try form.clearSignature(try XCTUnwrap(form.find("empty")))) {
            XCTAssertTrue($0 is InvalidOperationException)
        }
    }
}
