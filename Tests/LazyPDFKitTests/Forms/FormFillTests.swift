import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormFillTests.cs: the same cases. The C# font source reads Arial from the Windows
// fonts folder; here it is the synthetic font of the font program tests, which has A, B, space, ğ, İ and À, so the
// Turkish texts are made of those.

final class FormFillTests: XCTestCase {
    private func open(_ acroEntries: String = "", fonts: FontSource? = nil) throws -> PdfForm {
        PdfForm.read(try FormFixtures.open(acroEntries), fonts)
    }

    private func widget(_ form: PdfForm, _ name: String, _ index: Int = 0) throws -> FormWidget {
        try XCTUnwrap(form.find(name)).widgets[index]
    }

    private func normal(_ form: PdfForm, _ widget: FormWidget) throws -> PdfStream {
        let ap = try XCTUnwrap(form.document.dict(widget.dictionary, "AP"))
        return try XCTUnwrap(form.document.resolve(ap["N"]) as? PdfStream)
    }

    private func numbers(_ form: PdfForm, _ d: PdfDictionary, _ key: String) throws -> [Double] {
        try XCTUnwrap(form.document.array(d, key)).items.map { ($0 as? PdfNumber)?.value ?? .nan }
    }

    func test_textValueGetsAnAppearanceInTheFormsOwnFont() throws {
        let form = try open()

        let result = try form.setValue("name", "Ada Lovelace")

        XCTAssertEqual(result.filled, 1)
        XCTAssertEqual(try XCTUnwrap(form.find("name")).value, "Ada Lovelace")
        XCTAssertEqual(try FormFixtures.drawn(form.document, try widget(form, "name")), "Ada Lovelace")
        let stream = try normal(form, try widget(form, "name"))
        XCTAssertEqual(try numbers(form, stream.dictionary, "BBox"), [0, 0, 200, 20])
        let operators = ContentParser.parse(try form.document.data(stream)).map { $0.operator }
        XCTAssertTrue(operators.contains("BMC"))
        XCTAssertTrue(operators.contains("Tj"))
        XCTAssertTrue(Latin1.string(try form.document.data(stream)).contains("0 0 1 rg"))
        let fontTable = try XCTUnwrap(form.document.dict(form.document.dict(stream.dictionary, "Resources"), "Font"))
        XCTAssertEqual(fontTable.entries.count, 1)
        let used = fontTable.entries.first?.value
        let helv = form.document.dict(form.document.dict(form.acroForm, "DR"), "Font")?["Helv"]
        XCTAssertEqual(used as? PdfReference, helv as? PdfReference)
        let reopened = try AnnotationFixtures.reopen(form.document)
        XCTAssertEqual(PdfForm.read(reopened).find("name")?.value, "Ada Lovelace")
    }

    func test_clearingAValueRemovesItButKeepsTheFrame() throws {
        let form = try open()
        try form.setValue("name", "x")

        try form.setValue("name", nil)

        XCTAssertNil(try XCTUnwrap(form.find("name")).value)
        XCTAssertNotNil(form.document.dict(try widget(form, "name").dictionary, "AP"))
        XCTAssertEqual(try FormFixtures.drawn(form.document, try widget(form, "name")), "")
    }

    func test_turkishTextUsesAnAddedFontAndTheDefaultAppearanceFollowsIt() throws {
        let form = try open(fonts: try AnnotationFixtures.ArialSource())

        try form.setValue("name", "AğB İA")

        let field = try XCTUnwrap(form.find("name"))
        XCTAssertEqual(field.value, "AğB İA")
        XCTAssertEqual(try FormFixtures.drawn(form.document, field.widgets[0]), "AğB İA")
        XCTAssertTrue(try XCTUnwrap(field.defaultAppearance).hasPrefix("/LzF1 12 Tf"))
        let fonts = try XCTUnwrap(form.document.dict(form.document.dict(form.acroForm, "DR"), "Font"))
        XCTAssertTrue(fonts.containsKey("LzF1"))
        XCTAssertTrue(fonts.containsKey("Helv"))
        let embedded = try XCTUnwrap(form.document.resolve(fonts["LzF1"]) as? PdfDictionary)
        XCTAssertEqual(form.document.name(embedded, "Subtype"), "Type0")
        try AnnotationFixtures.reopen(form.document)
    }

    private final class CjkSource: FontSource {
        private let lacking: [UInt8]
        private let covering: [UInt8]?

        init(covering: Bool) throws {
            lacking = try SyntheticFonts.onlyA()
            self.covering = covering ? try SyntheticFonts.ttf() : nil
        }

        func find(_ family: String, _ style: FontStyles) -> FontFile? {
            if family == "Microsoft YaHei", let covering { return FontFile(covering) }
            return FontFile(lacking)
        }
    }

    func test_textTheFormFontLacksIsDrawnInAFallbackFont() throws {
        let form = try open(fonts: try CjkSource(covering: true))

        let result = try form.setValue("name", "AğB A")

        XCTAssertEqual(result.undrawn, "")
        XCTAssertEqual(try FormFixtures.drawn(form.document, try widget(form, "name")), "AğB A")
        let stream = try normal(form, try widget(form, "name"))
        let fonts = try XCTUnwrap(form.document.dict(form.document.dict(stream.dictionary, "Resources"), "Font"))
        let used = try XCTUnwrap(form.document.resolve(try XCTUnwrap(fonts.entries.first).value) as? PdfDictionary)
        XCTAssertEqual(form.document.name(used, "Subtype"), "Type0")
    }

    private final class ScriptSource: FontSource {
        private let data: [UInt8]

        init() throws { data = try ShapingGolden.font() }

        func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(data) }
    }

    func test_hebrewIsNotShownInASimpleFormFontThatEncodesIt() throws {
        let form = try open(fonts: try ScriptSource())
        let helv = try XCTUnwrap(form.document.resolve(try XCTUnwrap(form.document.dict(form.document.dict(form.acroForm, "DR"), "Font"))["Helv"]) as? PdfDictionary)
        let encoding = PdfDictionary()
        encoding["Differences"] = PdfArray([PdfNumber(224), PdfName("uni05E9"), PdfName("uni05DC"), PdfName("uni05D5"), PdfName("uni05DD")])
        helv["Encoding"] = encoding

        try form.setValue("name", "\u{05E9}\u{05DC}\u{05D5}\u{05DD}")

        let stream = try normal(form, try widget(form, "name"))
        let fonts = try XCTUnwrap(form.document.dict(form.document.dict(stream.dictionary, "Resources"), "Font"))
        let used = try XCTUnwrap(form.document.resolve(try XCTUnwrap(fonts.entries.first).value) as? PdfDictionary)
        XCTAssertEqual(form.document.name(used, "Subtype"), "Type0")
    }

    func test_charactersNoFontHasAreReportedAndTheFillSucceeds() throws {
        let form = try open(fonts: try CjkSource(covering: false))

        let result = try form.setValue("name", "BğBğA")

        XCTAssertEqual(result.filled, 1)
        XCTAssertEqual(result.undrawn, "Bğ")
        XCTAssertEqual(try XCTUnwrap(form.find("name")).value, "BğBğA")
    }

    func test_ordinaryTurkishFillLeavesNothingUndrawn() throws {
        let form = try open(fonts: try AnnotationFixtures.ArialSource())

        XCTAssertEqual(try form.setValue("name", "AğB İA").undrawn, "")
    }
    func test_fontNameWithReplacementSyntaxGoesIntoTheDefaultAppearanceLiterally() throws {
        let form = try open()
        let holder = PdfDictionary()

        form.setFontName(holder, "/Helv 12 Tf 0 g", "A$1B")

        XCTAssertEqual(PdfText.read(form.document, holder, "DA"), "/A$1B 12 Tf 0 g")
    }

    func test_fieldsOfOneBatchShareOneAddedFont() throws {
        let form = try open(fonts: try AnnotationFixtures.ArialSource())

        try form.setValues([("name", "AğB"), ("bio", "İBA")])

        let fonts = try XCTUnwrap(form.document.dict(form.document.dict(form.acroForm, "DR"), "Font"))
        XCTAssertEqual(fonts.entries.count, 2)
        let first = try XCTUnwrap(form.find("name")?.defaultAppearance).split(separator: " ")[0]
        let second = try XCTUnwrap(form.find("bio")?.defaultAppearance).split(separator: " ")[0]
        XCTAssertEqual(first, second)
    }

    func test_turkishTextWithoutAFontSourceChangesNothing() throws {
        let form = try open()

        XCTAssertThrowsError(try form.setValue("name", "ğ")) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, FormText.noFont)
        }

        XCTAssertNil(try XCTUnwrap(form.find("name")).value)
    }

    func test_checkBoxTakesExportValuesAndWords() throws {
        let form = try open()

        try form.setValue("agree", "Yes")
        XCTAssertTrue(try XCTUnwrap(form.find("agree")).isChecked)
        XCTAssertEqual(form.document.name(try widget(form, "agree").dictionary, "AS"), "Yes")

        try form.setValue("agree", "no")
        XCTAssertFalse(try XCTUnwrap(form.find("agree")).isChecked)
        XCTAssertEqual(form.document.name(try widget(form, "agree").dictionary, "AS"), "Off")

        try form.setValue("agree", "on")
        XCTAssertTrue(try XCTUnwrap(form.find("agree")).isChecked)
        XCTAssertTrue(try form.setValue("agree", "maybe").rejected.contains("agree"))
    }

    func test_radioGroupMovesTheChoiceAndRejectsUnknownOnes() throws {
        let form = try open()

        try form.setValue("choice", "b")
        let choice = try XCTUnwrap(form.find("choice"))
        XCTAssertEqual(choice.value, "b")
        XCTAssertEqual(choice.widgets.map { form.document.name($0.dictionary, "AS") }, ["Off", "b"])
        XCTAssertEqual(form.document.name(choice.dictionary, "V"), "b")

        try form.setValue("choice", "a")
        XCTAssertEqual(try XCTUnwrap(form.find("choice")).widgets.map { form.document.name($0.dictionary, "AS") }, ["a", "Off"])

        let result = try form.setValue("choice", "zzz")
        XCTAssertEqual(result.rejected, ["choice"])
        XCTAssertEqual(try XCTUnwrap(form.find("choice")).value, "a")
    }

    func test_radioExportsComeFromOpt() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [11 0 R 12 0 R]>>")
        pdf.obj(10, "<</T (size) /FT /Btn /Ff 32768 /Opt [(Small) (Large)] /Kids [11 0 R 12 0 R]>>")
        pdf.obj(11, "<</Type /Annot /Subtype /Widget /Parent 10 0 R /Rect [0 0 14 14] /P 3 0 R /AS /Off /AP <</N <</0 20 0 R /Off 20 0 R>>>>>>")
        pdf.obj(12, "<</Type /Annot /Subtype /Widget /Parent 10 0 R /Rect [30 0 44 14] /P 3 0 R /AS /Off /AP <</N <</1 20 0 R /Off 20 0 R>>>>>>")
        pdf.stream(20, "/Type /XObject /Subtype /Form /BBox [0 0 14 14]", "")
        let form = PdfForm.read(try PdfDocument.open(pdf.finish()))

        try form.setValue("size", "Large")

        let field = try XCTUnwrap(form.find("size"))
        XCTAssertEqual(field.value, "Large")
        XCTAssertEqual(form.document.name(field.dictionary, "V"), "1")
        XCTAssertEqual(field.widgets.map { form.document.name($0.dictionary, "AS") }, ["Off", "1"])
    }

    func test_comboTakesDisplayTextAndStoresTheExport() throws {
        let form = try open()

        try form.setValue("city", "Izmir")

        XCTAssertEqual(try XCTUnwrap(form.find("city")).value, "IZ")
        XCTAssertEqual(try FormFixtures.drawn(form.document, try widget(form, "city")), "Izmir")
        XCTAssertTrue(try form.setValue("city", "Nowhere").rejected.contains("city"))
    }

    func test_editableComboTakesAnyText() throws {
        let form = try open()
        try form.setFlag(try XCTUnwrap(form.find("city")), .edit, true)

        try form.setValue("city", "Nowhere")

        XCTAssertEqual(try XCTUnwrap(form.find("city")).value, "Nowhere")
    }

    func test_multiSelectListStoresValuesAndIndexes() throws {
        let form = try open()

        try form.setValue("langs", "English; German")

        let langs = try XCTUnwrap(form.find("langs"))
        XCTAssertEqual(langs.selected, ["English", "German"])
        XCTAssertEqual(try numbers(form, langs.dictionary, "I"), [1, 2])
        XCTAssertTrue(try FormFixtures.drawn(form.document, langs.widgets[0]).hasPrefix("TurkishEnglishGerman"))
    }

    func test_listScrollsToKeepTheSelectionVisible() throws {
        let form = try open()

        try form.setValue("langs", "Latin")

        let langs = try XCTUnwrap(form.find("langs"))
        XCTAssertTrue((form.document.number(langs.dictionary, "TI") ?? 0) > 0)
        let drawn = try FormFixtures.drawn(form.document, langs.widgets[0])
        XCTAssertTrue(drawn.hasSuffix("Latin"))
        XCTAssertFalse(drawn.contains("Turkish"))
    }

    func test_combFieldCutsAtMaxLengthAndSpacesTheCharacters() throws {
        let form = try open()

        try form.setValue("code", "1234567")

        XCTAssertEqual(try XCTUnwrap(form.find("code")).value, "123456")
        let recorder = GlyphBoxes()
        ContentInterpreter(form.document).run(try normal(form, try widget(form, "code")), recorder)
        XCTAssertEqual(recorder.lefts.count, 6)
        let step = recorder.lefts[1] - recorder.lefts[0]
        XCTAssertTrue(step >= 19 && step <= 21, "\(step)")
    }

    func test_passwordFieldDrawsBullets() throws {
        let form = try open()

        try form.setValue("secret", "abc")

        XCTAssertEqual(try XCTUnwrap(form.find("secret")).value, "abc")
        XCTAssertEqual(try FormFixtures.drawn(form.document, try widget(form, "secret")), "\u{2022}\u{2022}\u{2022}")
    }

    func test_multilineTextWrapsAtTheFieldWidth() throws {
        let form = try open()

        try form.setValue("bio", "one two three four five six seven eight nine ten eleven twelve thirteen\nsecond paragraph")

        let stream = try normal(form, try widget(form, "bio"))
        let lines = ContentParser.parse(try form.document.data(stream)).filter { $0.operator == "Tj" }.count
        XCTAssertTrue(lines >= 3, "\(lines) lines")
        XCTAssertTrue(try FormFixtures.drawn(form.document, try widget(form, "bio")).hasSuffix("second paragraph"))
    }

    func test_fieldsSharingANameChangeTogether() throws {
        let form = try Self.twoTextFields("/T (same) /DV (x)", "/T (same)")

        let result = try form.setValue("same", "both")

        XCTAssertEqual(result.filled, 2)
        for f in form.findAll("same") {
            XCTAssertEqual(f.value, "both")
            XCTAssertEqual(try FormFixtures.drawn(form.document, f.widgets[0]), "both")
        }
    }

    func test_unknownNamesAndButtonsAreReported() throws {
        let form = try open()

        let result = try form.setValues([("nothing", "x"), ("sig", "x"), ("name", "ok")])

        XCTAssertEqual(result.unknownFields, ["nothing"])
        XCTAssertEqual(result.rejected, ["sig"])
        XCTAssertEqual(result.filled, 1)
    }

    func test_resetReturnsFieldsToTheirDefaults() throws {
        let form = try Self.twoTextFields("/T (a) /DV (start) /V (start)", "/T (b) /V (leftover)")
        try form.setValue("a", "changed")

        XCTAssertEqual(try form.reset(), 2)

        XCTAssertEqual(try XCTUnwrap(form.find("a")).value, "start")
        XCTAssertNil(try XCTUnwrap(form.find("b")).value)
        XCTAssertEqual(try FormFixtures.drawn(form.document, try XCTUnwrap(form.find("a")).widgets[0]), "start")
    }

    func test_resetClearsCheckBoxesAndRadios() throws {
        let form = try open()
        try form.setValues([("agree", "Yes"), ("choice", "a")])

        try form.reset()

        XCTAssertFalse(try XCTUnwrap(form.find("agree")).isChecked)
        XCTAssertEqual(try XCTUnwrap(form.find("choice")).value, "Off")
        XCTAssertEqual(try XCTUnwrap(form.find("choice")).widgets.map { form.document.name($0.dictionary, "AS") }, ["Off", "Off"])
    }

    func test_rotatedWidgetsGetAMatrixThatTurnsTheDrawing() throws {
        let form = try Self.twoTextFields("/T (r) /Rect [0 0 20 100] /MK <</R 90>>", "/T (s)")

        try form.setValue("r", "turned")

        let stream = try normal(form, try XCTUnwrap(form.find("r")).widgets[0])
        XCTAssertEqual(try numbers(form, stream.dictionary, "BBox"), [0, 0, 100, 20])
        XCTAssertEqual(try numbers(form, stream.dictionary, "Matrix"), [0, 1, -1, 0, 20, 0])
    }

    func test_regenerateRedrawsEveryFieldFromItsValue() throws {
        let form = try open()
        try XCTUnwrap(form.find("name")).dictionary["V"] = PdfText.toObject("typed elsewhere")
        form.refresh()

        try form.regenerate()

        XCTAssertEqual(try FormFixtures.drawn(form.document, try widget(form, "name")), "typed elsewhere")
    }

    func test_staticXfaIsDroppedAndDynamicIsRefused() throws {
        let form = try open("/XFA [(template) 12 0 R]")
        XCTAssertEqual(form.xfa, .static)

        try form.setValue("name", "x")

        XCTAssertTrue(form.xfaRemoved)
        XCTAssertFalse(form.document.hasXfa)

        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /XFA [(template) 12 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        let dynamic = PdfForm.read(try PdfDocument.open(pdf.finish()))
        XCTAssertEqual(dynamic.xfa, .dynamic)
        assertReadFails(try dynamic.setValue("x", "y"), .unsupported)
        assertReadFails(try dynamic.reset())
    }

    // Two text fields on one page in a form with Helvetica as Helv; each argument is the rest of a widget dictionary.
    static func twoTextFields(_ first: String, _ second: String) throws -> PdfForm {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R 11 0 R] /DA (/Helv 10 Tf 0 g) /DR <</Font <</Helv 12 0 R>>>>>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R]>>")
        pdf.obj(10, "<</Type /Annot /Subtype /Widget /FT /Tx /Rect [0 0 100 20] /P 3 0 R \(first)>>")
        pdf.obj(11, "<</Type /Annot /Subtype /Widget /FT /Tx /Rect [0 40 100 60] /P 3 0 R \(second)>>")
        pdf.obj(12, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        return PdfForm.read(try PdfDocument.open(pdf.finish()))
    }

    private final class GlyphBoxes: ContentVisitor {
        var lefts: [Double] = []

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            lefts.append(glyph.bounds.left)
        }
    }
}
