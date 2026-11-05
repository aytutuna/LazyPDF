import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormReadTests.cs: the same cases.

final class FormReadTests: XCTestCase {
    func test_fieldsAreFoundWithKindsAndNames() throws {
        let form = PdfForm.read(try FormFixtures.open())

        XCTAssertEqual(form.fields.map { $0.name }, ["name", "bio", "agree", "choice", "city", "langs", "code", "secret", "sig"])
        XCTAssertEqual(try XCTUnwrap(form.find("name")).kind, .text)
        XCTAssertEqual(try XCTUnwrap(form.find("agree")).kind, .checkBox)
        XCTAssertEqual(try XCTUnwrap(form.find("choice")).kind, .radio)
        XCTAssertEqual(try XCTUnwrap(form.find("city")).kind, .comboBox)
        XCTAssertEqual(try XCTUnwrap(form.find("langs")).kind, .listBox)
        XCTAssertEqual(try XCTUnwrap(form.find("sig")).kind, .signature)
        XCTAssertTrue(try XCTUnwrap(form.find("bio")).has(.multiline))
        XCTAssertTrue(try XCTUnwrap(form.find("secret")).has(.password))
        XCTAssertTrue(try XCTUnwrap(form.find("code")).has(.comb))
        XCTAssertEqual(try XCTUnwrap(form.find("code")).maxLength, 6)
        XCTAssertFalse(try XCTUnwrap(form.find("sig")).isSigned)
    }

    func test_radioButtonsAreWidgetsOfOneField() throws {
        let choice = try XCTUnwrap(PdfForm.read(try FormFixtures.open()).find("choice"))

        XCTAssertEqual(choice.widgets.map { $0.onState }, ["a", "b"])
        for w in choice.widgets {
            assertSame(w.field, choice)
            XCTAssertEqual(w.pageIndex, 0)
        }
        XCTAssertEqual(choice.value, "Off")
    }

    func test_optionsKeepExportAndDisplayApart() throws {
        let city = try XCTUnwrap(PdfForm.read(try FormFixtures.open()).find("city"))

        XCTAssertEqual(city.options, [FieldOption("Ankara"), FieldOption("IZ", "Izmir"), FieldOption("Bursa")])
    }

    func test_valuesAndAttributesAreInheritedThroughTheTree() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R] /DA (/Helv 9 Tf 0 g) /Q 1>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [12 0 R 13 0 R]>>")
        pdf.obj(10, "<</T (person) /FT /Tx /Ff 2 /V (Ada) /Kids [11 0 R]>>")
        pdf.obj(11, "<</T (address) /Parent 10 0 R /MaxLen 20 /Kids [12 0 R 13 0 R]>>")
        pdf.obj(12, "<</Type /Annot /Subtype /Widget /Parent 11 0 R /Rect [0 0 100 20] /P 3 0 R>>")
        pdf.obj(13, "<</Type /Annot /Subtype /Widget /Parent 11 0 R /Rect [0 30 100 50] /P 3 0 R>>")
        let form = PdfForm.read(try PdfDocument.open(pdf.finish()))

        XCTAssertEqual(form.fields.count, 1)
        let field = try XCTUnwrap(form.fields.first)
        XCTAssertEqual(field.name, "person.address")
        XCTAssertEqual(field.partialName, "address")
        XCTAssertEqual(field.value, "Ada")
        XCTAssertEqual(field.maxLength, 20)
        XCTAssertEqual(field.alignment, 1)
        XCTAssertEqual(field.defaultAppearance, "/Helv 9 Tf 0 g")
        XCTAssertTrue(field.has(.required))
        XCTAssertEqual(field.widgets.count, 2)
    }

    func test_widgetsNotInTheFieldListAreOrphans() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /DA (/Helv 0 Tf 0 g)>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R]>>")
        pdf.obj(10, "<</Type /Annot /Subtype /Widget /FT /Tx /T (lost) /V (still here) /Rect [0 0 100 20] /P 3 0 R>>")
        pdf.obj(11, "<</Type /Annot /Subtype /Widget /Rect [0 30 100 50] /P 3 0 R>>")
        let form = PdfForm.read(try PdfDocument.open(pdf.finish()))

        XCTAssertEqual(form.orphans.count, 1)
        let orphan = try XCTUnwrap(form.orphans.first)
        XCTAssertEqual(orphan.name, "lost")
        XCTAssertEqual(orphan.value, "still here")
        XCTAssertTrue(orphan.isOrphan)
    }

    func test_documentWithoutAcroFormHasNoFields() throws {
        let form = PdfForm.read(try AnnotationFixtures.blank())

        XCTAssertTrue(form.fields.isEmpty)
        XCTAssertEqual(form.xfa, .none)
    }

    func test_loopsAndDeepTreesDoNotHang() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R 10 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(10, "<</T (a) /FT /Tx /Kids [11 0 R]>>")
        pdf.obj(11, "<</T (b) /Parent 10 0 R /Kids [10 0 R 11 0 R]>>")
        let form = PdfForm.read(try PdfDocument.open(pdf.finish()))

        XCTAssertTrue(form.fields.isEmpty)
    }

    func test_choiceValuesAreRead() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(10, "<</T (l) /FT /Ch /Ff 2097152 /Opt [(a) (b) (c)] /V [(a) (c)]>>")
        let fields = PdfForm.read(try PdfDocument.open(pdf.finish())).fields
        XCTAssertEqual(fields.count, 1)
        let field = try XCTUnwrap(fields.first)

        XCTAssertEqual(field.selected, ["a", "c"])
        XCTAssertTrue(field.widgets.isEmpty)
    }
}
