import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormStyleTests.cs: the same cases. The font source is the synthetic font (A, B, space, ğ, İ and À).

final class FormStyleTests: XCTestCase {
    private func standard() throws -> PdfForm { PdfForm.read(try FormFixtures.open()) }

    private func blank() throws -> PdfForm { PdfForm.read(try AnnotationFixtures.blank()) }

    private func button(_ form: PdfForm) throws -> FormField {
        try form.addField(FieldSpec(.pushButton, "go", 0, PdfRect(300, 100, 400, 124), caption: "Go"))
        return try XCTUnwrap(form.find("go"))
    }

    func test_theOnStateOfACheckBoxIsRenamedAndTheValueFollows() throws {
        let form = try standard()
        try form.setValue("agree", "Yes")

        try form.setExportValue(try XCTUnwrap(form.find("agree")).widgets[0], "Accepted")

        let reopened = PdfForm.read(try AnnotationFixtures.reopen(form.document))
        let field = try XCTUnwrap(reopened.find("agree"))
        XCTAssertEqual(field.widgets[0].onState, "Accepted")
        XCTAssertEqual(field.widgets[0].export, "Accepted")
        XCTAssertTrue(field.isChecked)
        XCTAssertEqual(field.value, "Accepted")
        XCTAssertNotNil(reopened.document.dict(reopened.document.dict(field.widgets[0].dictionary, "AP"), "N")?["Off"])
    }

    func test_aRadioButtonCanTakeAnyUnusedValueAndSettingItAgainDoesNothing() throws {
        let form = try standard()

        try form.setExportValue(try XCTUnwrap(form.find("choice")).widgets[1], "Second choice")
        try form.setExportValue(try XCTUnwrap(form.find("choice")).widgets[1], "Second choice")
        try form.setValue("choice", "Second choice")

        let reopened = PdfForm.read(try AnnotationFixtures.reopen(form.document))
        XCTAssertEqual(reopened.find("choice")?.value, "Second choice")
        XCTAssertEqual(try XCTUnwrap(reopened.find("choice")).widgets.map { $0.onState }, ["a", "Second choice"])
    }

    func test_anExportValueAnotherButtonHasIsRefused() throws {
        let form = try standard()

        XCTAssertThrowsError(try form.setExportValue(try XCTUnwrap(form.find("choice")).widgets[1], "a")) { error in
            XCTAssertTrue(error is InvalidOperationException)
        }
        assertArgumentException(try form.setExportValue(try XCTUnwrap(form.find("choice")).widgets[1], "Off"))
        assertArgumentException(try form.setExportValue(try XCTUnwrap(form.find("choice")).widgets[1], "  "))
        assertArgumentException(try form.setExportValue(try XCTUnwrap(form.find("name")).widgets[0], "x"))
    }

    func test_aRadioGroupWithOptionsKeepsItsStatesAndChangesTheOption() throws {
        let form = try blank()
        try form.addField(FieldSpec(.radio, "size", 0, PdfRect(50, 700, 64, 714), exportValue: "S"))
        try form.addWidget(try XCTUnwrap(form.find("size")), 0, PdfRect(100, 700, 114, 714), "M")
        try XCTUnwrap(form.find("size")).dictionary["Opt"] = PdfArray([PdfText.toObject("S"), PdfText.toObject("M")])
        form.refresh()

        try form.setExportValue(try XCTUnwrap(form.find("size")).widgets[1], "Medium")

        let field = try XCTUnwrap(PdfForm.read(try AnnotationFixtures.reopen(form.document)).find("size"))
        XCTAssertEqual(field.widgets.map { $0.export }, ["S", "Medium"])
        XCTAssertEqual(field.widgets.map { $0.onState }, ["S", "M"])
    }

    func test_fontSizeAndColourChangeTheDefaultAppearanceAndTheDrawing() throws {
        let form = try standard()
        try form.setValue("name", "Ada")

        try form.setFont(try XCTUnwrap(form.find("name")), "TiRo")
        try form.setFontSize(try XCTUnwrap(form.find("name")), 18)
        try form.setTextColor(try XCTUnwrap(form.find("name")), [1, 0, 0])

        let field = try XCTUnwrap(PdfForm.read(try AnnotationFixtures.reopen(form.document)).find("name"))
        XCTAssertEqual(field.defaultAppearance, "/TiRo 18 Tf 1 0 0 rg")
        XCTAssertEqual(field.value, "Ada")
        XCTAssertEqual(try FormFixtures.drawn(form.document, field.widgets[0]), "Ada")
        let fonts = try XCTUnwrap(form.document.dict(form.document.dict(form.acroForm, "DR"), "Font"))
        XCTAssertTrue(fonts.containsKey("TiRo"))
    }

    func test_aCheckBoxMarkTakesTheTextColour() throws {
        let form = try standard()
        try form.setValue("agree", "Yes")

        try form.setTextColor(try XCTUnwrap(form.find("agree")), [0.2, 0.4, 0.6])

        let widget = try XCTUnwrap(form.find("agree")).widgets[0]
        let states = try XCTUnwrap(form.document.dict(form.document.dict(widget.dictionary, "AP"), "N"))
        let on = try XCTUnwrap(form.document.resolve(states["Yes"]) as? PdfStream)
        XCTAssertTrue(Latin1.string(try form.document.data(on)).contains("0.2 0.4 0.6"))
        XCTAssertTrue(try XCTUnwrap(form.find("agree")).isChecked)
    }

    func test_aBadFontSizeColourOrFontIsRefused() throws {
        let form = try standard()
        let field = try XCTUnwrap(form.find("name"))

        assertArgumentException(try form.setFont(field, "Nope"))
        assertArgumentException(try form.setFontSize(field, -1))
        assertArgumentException(try form.setFontSize(field, 300))
        assertArgumentException(try form.setTextColor(field, [1, 2, 3, 4, 5]))
        assertArgumentException(try form.setTextColor(field, [0, 0]))
        assertArgumentException(try form.setTextColor(field, [2]))
        XCTAssertEqual(form.find("name")?.defaultAppearance, "/Helv 12 Tf 0 0 1 rg")
    }

    func test_theLookOfATextFieldIsReadFromItsDefaultAppearance() throws {
        let form = try standard()

        let look = form.getTextLook(try XCTUnwrap(form.find("name")))

        XCTAssertEqual(look.font, "Helv")
        XCTAssertEqual(look.size, 12)
        XCTAssertEqual(look.color, [0, 0, 1])
        XCTAssertEqual(form.getTextLook(try XCTUnwrap(form.find("bio"))).size, 0)
    }

    func test_aButtonOpensALinkResetsOrSubmits() throws {
        let form = try blank()
        let go = try button(form)

        try form.setButtonAction(go, ButtonAction(.openLink, " https://example.com/a "))
        let link = PdfForm.read(try AnnotationFixtures.reopen(form.document))
        let linked = link.getButtonAction(try XCTUnwrap(link.find("go")))
        XCTAssertEqual(linked.kind, .openLink)
        XCTAssertEqual(linked.target, "https://example.com/a")

        try form.setButtonAction(try XCTUnwrap(form.find("go")), ButtonAction(.reset))
        XCTAssertEqual(form.getButtonAction(try XCTUnwrap(form.find("go"))).kind, .reset)

        try form.setButtonAction(try XCTUnwrap(form.find("go")), ButtonAction(.submit, "https://example.com/post"))
        let read = PdfForm.read(try AnnotationFixtures.reopen(form.document))
        let submitted = read.getButtonAction(try XCTUnwrap(read.find("go")))
        XCTAssertEqual(submitted.kind, .submit)
        XCTAssertEqual(submitted.target, "https://example.com/post")
        let action = PdfActions.read(read.document, try XCTUnwrap(read.find("go")).widgets[0].dictionary["A"])
        let submit = try XCTUnwrap(action as? SubmitFormAction)
        XCTAssertEqual(submit.flags, 4)
    }

    func test_aButtonShowsOrHidesAFieldAndCanLoseItsAction() throws {
        let form = try blank()
        try form.addField(FieldSpec(.text, "notes", 0, PdfRect(50, 600, 250, 620)))
        let go = try button(form)

        try form.setButtonAction(go, ButtonAction(.hide, "notes"))
        let hide = PdfForm.read(try AnnotationFixtures.reopen(form.document))
        let hidden = hide.getButtonAction(try XCTUnwrap(hide.find("go")))
        XCTAssertEqual(hidden.kind, .hide)
        XCTAssertEqual(hidden.target, "notes")

        try form.setButtonAction(try XCTUnwrap(form.find("go")), ButtonAction(.show, "notes"))
        let shown = form.getButtonAction(try XCTUnwrap(form.find("go")))
        XCTAssertEqual(shown.kind, .show)
        XCTAssertEqual(shown.target, "notes")

        try form.setButtonAction(try XCTUnwrap(form.find("go")), ButtonAction(.none))
        XCTAssertEqual(form.getButtonAction(try XCTUnwrap(form.find("go"))).kind, ButtonActionKind.none)
        XCTAssertNil(try XCTUnwrap(form.find("go")).widgets[0].dictionary["A"])
    }

    func test_buttonActionsThatCannotBeWrittenAreRefused() throws {
        let form = try blank()
        try form.addField(FieldSpec(.text, "notes", 0, PdfRect(50, 600, 250, 620)))
        let go = try button(form)

        assertArgumentException(try form.setButtonAction(go, ButtonAction(.openLink, " ")))
        assertArgumentException(try form.setButtonAction(go, ButtonAction(.other)))
        XCTAssertThrowsError(try form.setButtonAction(go, ButtonAction(.hide, "missing"))) { error in
            XCTAssertTrue(error is InvalidOperationException)
        }
        assertArgumentException(try form.setButtonAction(try XCTUnwrap(form.find("notes")), ButtonAction(.reset)))
        XCTAssertNil(try XCTUnwrap(form.find("go")).widgets[0].dictionary["A"])
    }

    func test_anActionTheEngineDoesNotWriteIsReadAsOther() throws {
        let form = try blank()
        let go = try button(form)
        let script = PdfDictionary()
        script["S"] = PdfName("JavaScript")
        script["JS"] = PdfText.toObject("app.alert(1)")
        go.widgets[0].dictionary["A"] = script

        XCTAssertEqual(form.getButtonAction(go).kind, .other)
    }

    func test_changingOnlyTheFontDrawsInThatFont() throws {
        let form = try standard()
        try form.setValue("name", "Ada")

        try form.setFont(try XCTUnwrap(form.find("name")), "Cour")

        let fonts = try XCTUnwrap(form.document.dict(form.document.dict(form.acroForm, "DR"), "Font"))
        XCTAssertTrue(fonts.containsKey("Cour"))
        let d = form.document
        let ap = try XCTUnwrap(d.dict(try XCTUnwrap(form.find("name")).widgets[0].dictionary, "AP"))
        let stream = try XCTUnwrap(d.resolve(ap["N"]) as? PdfStream)
        let used = try XCTUnwrap(d.dict(d.dict(stream.dictionary, "Resources"), "Font"))
        for e in used.entries { XCTAssertEqual(d.name(d.dict(used, e.key), "BaseFont"), "Courier") }
    }

    func test_sizeAndColourSurviveAFieldThatNeedsAnEmbeddedFont() throws {
        let form = PdfForm.read(try AnnotationFixtures.blank(), try AnnotationFixtures.ArialSource())
        try form.addField(FieldSpec(.text, "tr", 0, PdfRect(50, 700, 250, 720), value: "AİB"))

        try form.setFontSize(try XCTUnwrap(form.find("tr")), 18)
        try form.setTextColor(try XCTUnwrap(form.find("tr")), [1, 0, 0])

        let look = form.getTextLook(try XCTUnwrap(form.find("tr")))
        XCTAssertEqual(look.size, 18)
        XCTAssertEqual(look.color, [1, 0, 0])
    }

    func test_aCheckBoxPlacedTwiceRenamesItsStateEverywhere() throws {
        let form = try blank()
        try form.addField(FieldSpec(.checkBox, "ok", 0, PdfRect(50, 700, 64, 714)))
        try form.addWidget(try XCTUnwrap(form.find("ok")), 0, PdfRect(100, 700, 114, 714))
        try form.setValue("ok", "Yes")

        try form.setExportValue(try XCTUnwrap(form.find("ok")).widgets[0], "On")

        let field = try XCTUnwrap(form.find("ok"))
        for w in field.widgets { XCTAssertEqual(w.onState, "On") }
        XCTAssertTrue(field.isChecked)
    }

    func test_showAndHideActionsFollowARenameAndGoWithARemovedField() throws {
        let form = try blank()
        try form.addField(FieldSpec(.text, "notes", 0, PdfRect(50, 600, 250, 620)))
        try form.setButtonAction(try button(form), ButtonAction(.hide, "notes"))

        try form.rename(try XCTUnwrap(form.find("notes")), "remarks")
        let renamed = form.getButtonAction(try XCTUnwrap(form.find("go")))
        XCTAssertEqual(renamed.kind, .hide)
        XCTAssertEqual(renamed.target, "remarks")

        try form.remove(try XCTUnwrap(form.find("remarks")))
        XCTAssertEqual(form.getButtonAction(try XCTUnwrap(form.find("go"))).kind, ButtonActionKind.none)
    }
}
