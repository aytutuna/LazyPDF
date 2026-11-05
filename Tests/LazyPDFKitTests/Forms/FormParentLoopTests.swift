import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormParentLoopTests.cs: the same cases, with the ten seconds as an expectation.

final class FormParentLoopTests: XCTestCase {
    func test_clearing_a_field_whose_parents_form_a_loop_ends() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [5 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [5 0 R]>>")
        pdf.obj(5, "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 50 20] /V (x) /Parent 6 0 R>>")
        pdf.obj(6, "<</T (p) /Parent 7 0 R>>")
        pdf.obj(7, "<</T (q) /Parent 6 0 R>>")
        let document = try PdfDocument.open(pdf.finish())
        let form = PdfForm.read(document)
        let done = expectation(description: "reset ends")

        DispatchQueue.global().async {
            _ = try? form.reset()
            done.fulfill()
        }

        wait(for: [done], timeout: 10)
    }

    func test_removing_a_field_whose_parent_is_its_own_parent_ends() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [5 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [6 0 R]>>")
        pdf.obj(5, "<</T (a) /Kids [6 0 R] /Parent 5 0 R>>")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (b) /Rect [0 0 50 20] /P 3 0 R /Parent 5 0 R>>")
        let form = PdfForm.read(try PdfDocument.open(pdf.finish()))
        let field = try XCTUnwrap(form.find("a.b"))
        let done = expectation(description: "remove ends")

        DispatchQueue.global().async {
            _ = try? form.remove(field)
            done.fulfill()
        }

        wait(for: [done], timeout: 10)
    }

    func test_removing_a_field_under_two_parents_that_name_each_other_ends() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [5 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [7 0 R]>>")
        pdf.obj(5, "<</T (a) /Kids [7 0 R] /Parent 6 0 R>>")
        pdf.obj(6, "<</T (p) /Kids [] /Parent 5 0 R>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Widget /FT /Tx /T (b) /Rect [0 0 50 20] /P 3 0 R /Parent 5 0 R>>")
        let form = PdfForm.read(try PdfDocument.open(pdf.finish()))
        let field = try XCTUnwrap(form.find("a.b"))
        let done = expectation(description: "remove ends")

        DispatchQueue.global().async {
            _ = try? form.remove(field)
            done.fulfill()
        }

        wait(for: [done], timeout: 10)
    }
}
