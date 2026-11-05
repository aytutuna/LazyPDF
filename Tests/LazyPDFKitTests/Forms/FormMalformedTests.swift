import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormMalformedTests.cs: the same cases.

final class FormMalformedTests: XCTestCase {
    private func build(_ acro: String, _ objects: String...) throws -> PdfForm {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm \(acro)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R]>>")
        for (i, body) in objects.enumerated() { pdf.obj(10 + i, body) }
        return PdfForm.read(try PdfDocument.open(pdf.finish()))
    }

    func test_junkInTheFieldListIsSkipped() throws {
        let form = try build("<</Fields [null 5 (text) 10 0 R 99 0 R <</T (direct) /FT /Tx>>]>>",
                             "<</Type /Annot /Subtype /Widget /FT /Tx /T (ok) /Rect [0 0 100 20] /P 3 0 R>>")

        XCTAssertEqual(form.fields.map { $0.name }, ["ok", "direct"])
        XCTAssertTrue(form.fields[1].widgets.isEmpty)
    }

    func test_fieldsThatIsNotAnArrayGivesAnEmptyFormButOrphansAreStillFound() throws {
        let form = try build("<</Fields 5>>", "<</Type /Annot /Subtype /Widget /FT /Tx /T (lost) /Rect [0 0 100 20]>>")

        XCTAssertEqual(form.fields.count, 1)
        let orphan = try XCTUnwrap(form.fields.first)
        XCTAssertTrue(orphan.isOrphan)
        XCTAssertEqual(orphan.widgets[0].pageIndex, 0)
    }

    func test_badValuesAndOptionsReadAsDefaults() throws {
        let form = try build("<</Fields [10 0 R 11 0 R]>>",
                             "<</Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /T (c) /V 12 /Opt [(a) 5 [(x)] [1 2] null] /MaxLen -4 /Q 9 /Rect [0 0 100 20] /P 3 0 R>>",
                             "<</Type /Annot /Subtype /Widget /FT /Btn /T (b) /V 3 /AP <</N 7>> /Rect [0 30 14 44] /P 3 0 R>>")

        let combo = try XCTUnwrap(form.find("c"))
        XCTAssertNil(combo.value)
        XCTAssertEqual(Array(combo.options.prefix(1)), [FieldOption("a")])
        XCTAssertEqual(combo.maxLength, 0)
        XCTAssertEqual(form.find("b")?.value, "Off")
        XCTAssertNil(form.find("b")?.widgets[0].onState)
    }

    func test_fillingWorksWithoutDefaultsFontsOrSaneGeometry() throws {
        let form = try build("<</Fields [10 0 R 11 0 R]>>",
                             "<</Type /Annot /Subtype /Widget /FT /Tx /T (t) /DA (garbage) /MK <</R 45 /BC 3 /BG [1 2]>> /Rect [0 0 100 20] /P 3 0 R>>",
                             "<</Type /Annot /Subtype /Widget /FT /Tx /T (flat) /Rect [5 5 5 5] /P 3 0 R>>")

        let result = try form.setValues([("t", "hello"), ("flat", "zero area")])

        XCTAssertEqual(result.filled, 2)
        XCTAssertEqual(try FormFixtures.drawn(form.document, try XCTUnwrap(form.find("t")).widgets[0]), "hello")
        XCTAssertNil(form.document.dict(try XCTUnwrap(form.find("flat")).widgets[0].dictionary, "AP"))
        XCTAssertEqual(form.document.dict(form.document.dict(form.acroForm, "DR"), "Font")?.containsKey("Helv"), true)
        try AnnotationFixtures.reopen(form.document)
    }

    func test_aDefaultFontThatIsNotInTheResourcesIsAddedUnderItsName() throws {
        let form = try build("<</Fields [10 0 R] /DA (/TiRo 10 Tf 0 g)>>",
                             "<</Type /Annot /Subtype /Widget /FT /Tx /T (t) /Rect [0 0 100 20] /P 3 0 R>>")

        try form.setValue("t", "serif")

        let fonts = try XCTUnwrap(form.document.dict(form.document.dict(form.acroForm, "DR"), "Font"))
        let added = try XCTUnwrap(form.document.resolve(fonts["TiRo"]) as? PdfDictionary)
        XCTAssertTrue(try XCTUnwrap(form.document.name(added, "BaseFont")).contains("Times"))
    }

    func test_valuesStoredAsStreamsAreRead() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(10, "<</FT /Tx /T (long) /V 11 0 R>>")
        pdf.stream(11, "", "from a stream")

        let fields = PdfForm.read(try PdfDocument.open(pdf.finish())).fields
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.value, "from a stream")
    }

    func test_removingAndRenamingFieldsOutsideTheTreeIsHarmless() throws {
        let form = try build("<</Fields []>>", "<</Type /Annot /Subtype /Widget /FT /Tx /T (lost) /Rect [0 0 100 20] /P 3 0 R>>")
        XCTAssertEqual(form.fields.count, 1)
        let orphan = try XCTUnwrap(form.fields.first)

        try form.rename(orphan, "found")
        try form.remove(try XCTUnwrap(form.find("found")))

        XCTAssertTrue(form.fields.isEmpty)
    }

    func test_signedSignatureFieldsAreReportedAndNeverFilled() throws {
        let form = try build("<</Fields [10 0 R]>>", "<</Type /Annot /Subtype /Widget /FT /Sig /T (s) /V <</Type /Sig /Filter /Adobe.PPKLite>> /Rect [0 0 100 20] /P 3 0 R>>")

        XCTAssertEqual(form.fields.count, 1)
        let field = try XCTUnwrap(form.fields.first)

        XCTAssertTrue(field.isSigned)
        XCTAssertEqual(try form.setValue("s", "x").rejected, ["s"])
        XCTAssertTrue(form.canFill)
    }

    func test_aWidgetWithoutARectangleCannotBeMoved() throws {
        let form = try build("<</Fields [10 0 R]>>", "<</Type /Annot /Subtype /Widget /FT /Tx /T (t) /P 3 0 R>>")

        assertArgumentException(try form.move(try XCTUnwrap(form.find("t")).widgets[0], 5, 5))
    }
}
