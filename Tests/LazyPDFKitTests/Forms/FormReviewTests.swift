import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormReviewTests.cs: the same cases, and the cases of the review that fixed the
// Swift-only traps, which the C# tests carry too.

final class FormReviewTests: XCTestCase {
    private let box = PdfRect(50, 700, 250, 720)

    private func blank() throws -> PdfForm { PdfForm.read(try AnnotationFixtures.blank()) }

    private func call(_ source: String) throws -> FormCall { try XCTUnwrap(FormScriptParser.parse(source)?.first) }

    func test_addWidgetKeepsTheFirstWidgetOnItsPageWithoutP() throws {
        let form = try blank()
        try form.addField(FieldSpec(.text, "t", 0, box))
        try XCTUnwrap(form.find("t")).dictionary.remove("P")

        try form.addWidget(try XCTUnwrap(form.find("t")), 0, PdfRect(50, 600, 250, 620))

        let field = try XCTUnwrap(form.find("t"))
        XCTAssertEqual(field.widgets.map { $0.pageIndex }, [0, 0])
        for w in field.widgets { XCTAssertEqual(form.document.name(w.dictionary, "Subtype"), "Widget") }
        XCTAssertTrue(field.widgets[1].dictionary.containsKey("MK"))
    }

    func test_aNewRadioButtonDoesNotShareAStateAfterARemoval() throws {
        let form = try blank()
        try form.addField(FieldSpec(.radio, "r", 0, PdfRect(50, 700, 64, 714)))
        try form.addWidget(try XCTUnwrap(form.find("r")), 0, PdfRect(80, 700, 94, 714))
        try form.addWidget(try XCTUnwrap(form.find("r")), 0, PdfRect(110, 700, 124, 714))
        try form.remove(try XCTUnwrap(form.find("r")).widgets[1])
        try form.addWidget(try XCTUnwrap(form.find("r")), 0, PdfRect(140, 700, 154, 714))

        let states = try XCTUnwrap(form.find("r")).widgets.map { $0.onState }
        XCTAssertEqual(states.count, Set(states.map { $0 ?? "" }).count)
    }

    func test_aDateIsReadInTheFieldsOwnFormat() throws {
        XCTAssertEqual(FormFunctions.format(try call("AFDate_FormatEx(\"dd/mm/yyyy\")"), "03/04/2024")?.text, "03/04/2024")
    }

    func test_aNumberWithADotGroupMarkKeepsItsValue() throws {
        XCTAssertEqual(FormFunctions.format(try call("AFNumber_Format(2, 2, 0, 0, \"\", true)"), "1.234")?.text, "1.234,00")
    }

    func test_aLongPhoneNumberIsShownWhole() throws {
        XCTAssertNil(FormFunctions.format(try call("AFSpecial_Format(2)"), "123456789012"))
    }

    func test_redrawingAnIconButtonLeavesItsAppearance() throws {
        let form = try blank()
        try form.addField(FieldSpec(.pushButton, "go", 0, PdfRect(50, 700, 150, 730)))
        let widget = try XCTUnwrap(form.find("go")).widgets[0]
        let mk = PdfDictionary()
        mk["I"] = PdfReference(1, 0)
        mk["CA"] = PdfText.toObject("x")
        widget.dictionary["MK"] = mk
        let before = widget.dictionary["AP"]

        try form.move(widget, 10, 0)

        assertSame(before, try XCTUnwrap(form.find("go")).widgets[0].dictionary["AP"])
    }

    func test_partialFlattenLeavesNoDeadFieldEntries() throws {
        let form = try blank()
        try form.addField(FieldSpec(.text, "a", 0, box, value: "x"))
        try form.addField(FieldSpec(.text, "b", 0, PdfRect(50, 600, 250, 620)))

        try form.flatten([try XCTUnwrap(form.find("a"))])

        let fields = try XCTUnwrap(form.document.array(form.acroForm, "Fields"))
        XCTAssertEqual(fields.items.count, 1)
        XCTAssertNotNil(form.document.resolve(fields.items[0]))
    }

    func test_clearingAFlagTheParentSetsWritesAnExplicitZero() throws {
        var form = try blank()
        try form.addField(FieldSpec(.text, "g.t", 0, box))
        var field = try XCTUnwrap(form.find("g.t"))
        let parent = try XCTUnwrap(form.document.dict(field.dictionary, "Parent"))
        parent["Ff"] = PdfNumber(1)
        field.dictionary["Ff"] = PdfNumber(1)
        form = PdfForm.read(form.document)
        field = try XCTUnwrap(form.find("g.t"))
        XCTAssertTrue(field.has(.readOnly))

        try form.setFlag(field, .readOnly, false)

        XCTAssertFalse(try XCTUnwrap(form.find("g.t")).has(.readOnly))
    }

    func test_aCheckBoxWithAStringValueIsExportedAsItsOnState() throws {
        var form = PdfForm.read(try FormFixtures.open())
        let check = try XCTUnwrap(form.find("agree"))
        check.dictionary["V"] = PdfText.toObject("Yes")
        check.widgets[0].dictionary["AS"] = PdfName("Yes")
        form = PdfForm.read(form.document)
        XCTAssertTrue(try XCTUnwrap(form.find("agree")).isChecked)

        let value = form.exportFdf().fields.first { $0.name == "agree" }?.value
        XCTAssertEqual((value as? PdfName)?.value, "Yes")
    }

    func test_aToUnicodeEntryThatIsHalfOfAPairDoesNotStopTheDrawing() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R] /DR <</Font <</Helv 11 0 R>>>>>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R]>>")
        pdf.obj(10, "<</Type /Annot /Subtype /Widget /FT /Tx /T (t) /DA (/Helv 12 Tf 0 g) /Rect [0 0 100 20] /P 3 0 R>>")
        pdf.obj(11, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 12 0 R>>")
        pdf.stream(12, "", "begincmap 1 begincodespacerange <00> <FF> endcodespacerange 1 beginbfchar <41> <D800> endbfchar endcmap")
        let form = PdfForm.read(try PdfDocument.open(pdf.finish()))

        try form.setValue("t", "B")

        XCTAssertEqual(try FormFixtures.drawn(form.document, try XCTUnwrap(form.find("t")).widgets[0]), "B")
    }

    func test_aPercentTooLargeToShowFallsBackToTheRawValue() throws {
        let huge = "1" + String(repeating: "0", count: 307)

        XCTAssertNil(FormFunctions.format(try call("AFPercent_Format(2, 0)"), huge))
    }

    func test_aLargeWholeNumberIsWrittenAsItIs() {
        XCTAssertEqual(FormFunctions.numberText(2e15), "2000000000000000")
        XCTAssertEqual(FormFunctions.numberText(1234567890123456), "1234567890123456")
        XCTAssertEqual(FormFunctions.numberText(2e16), "20000000000000000")
        XCTAssertEqual(FormFunctions.numberText(1e17), "1E+17")
    }

    func test_aDateOrTimeIsReadByTheFieldsOwnFormat() throws {
        let cases = [
            ("mmmm d, yyyy", "12/25/35", "December 25, 2035"),
            ("mmmm d, yyyy", "12/25/50", "December 25, 1950"),
            ("dd/mm/yyyy hh:MM", "03/04/2024 05:30", "03/04/2024 05:30"),
            ("HHH:MM", "05:30", "05:30"),
        ]
        for (format, value, shown) in cases {
            XCTAssertEqual(FormFunctions.format(try call("AFDate_FormatEx(\"\(format)\")"), value)?.text, shown, "\(format) \(value)")
        }
    }

    func test_aLongRunOfHourLettersIsNotADate() throws {
        let format = String(repeating: "H", count: 20)

        XCTAssertNil(FormFunctions.format(try call("AFDate_FormatEx(\"\(format)\")"), "99999999999999999999"))
    }

    func test_aWidgetKeptAcrossAChangeStillBelongsToItsField() throws {
        let form = try blank()
        let field = try form.addField(FieldSpec(.text, "t", 0, box))
        let widget = try form.addWidget(field, 0, PdfRect(50, 600, 250, 620))
        try form.setValue("t", "x")

        try form.resize(widget, PdfRect(50, 600, 350, 640))
        try form.remove(widget)

        XCTAssertEqual(try XCTUnwrap(form.find("t")).widgets.count, 1)
        XCTAssertEqual(try FormFixtures.drawn(form.document, try XCTUnwrap(form.find("t")).widgets[0]), "x")
    }

    func test_namesThatDifferOnlyInHowAnAccentIsWrittenAreTwoFields() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R 11 0 R] /DA (/Helv 0 Tf 0 g)>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R]>>")
        pdf.obj(10, "<</Type /Annot /Subtype /Widget /FT /Tx /T <FEFF00E9> /Rect [0 0 100 20] /P 3 0 R>>")
        pdf.obj(11, "<</Type /Annot /Subtype /Widget /FT /Tx /T <FEFF00650301> /Rect [0 30 100 50] /P 3 0 R>>")
        let form = PdfForm.read(try PdfDocument.open(pdf.finish()))

        XCTAssertEqual(form.fields.count, 2)
        XCTAssertEqual(form.findAll("\u{00E9}").count, 1)
        XCTAssertEqual(form.findAll("e\u{0301}").count, 1)
        XCTAssertEqual(form.exportFdf().fields.count, 2)
        XCTAssertEqual(FormCsv.read(form.exportCsv()).first?.count, 2)
    }
}
