import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/forms/FormEditsTests.cs: what the Forms panel changes in a tab, against real engine
// calls: one undoable step each, and the engine's refusals. Left out of the Windows folder: ScanFormCorpusTests, which reads the files a
// list in LAZYPDF_CORPUS names and does nothing without one; ScanFormTests is in ScanFormTests.swift, drawn by PDFKit.

@MainActor
final class FormEditsTests: XCTestCase {
    private let fonts = FormPdfs.fonts

    func test_fillingAFieldIsOneUndoableStep() throws {
        let tab = try FormPdfs.tab()
        var raised = 0
        tab.changed = { raised += 1 }

        let result = try FormEdits.apply(tab, fonts, "Fill form field") { try $0.setValue("name", "Ada") }

        XCTAssertEqual(result.filled, 1)
        XCTAssertEqual(raised, 1)
        XCTAssertEqual(tab.session.undoLabel, "Fill form field")
        XCTAssertEqual(FormPdfs.read(tab).find("name")?.value, "Ada")
        try tab.undo()
        XCTAssertNil(FormPdfs.read(tab).find("name")?.value)
    }

    func test_textIsCutAtTheLongestTheFieldTakes() throws {
        let tab = try FormPdfs.tab()

        _ = try FormEdits.apply(tab, fonts, "Fill form field") { try $0.setValue("code", "123456") }

        XCTAssertEqual(FormPdfs.read(tab).find("code")?.value, "1234")
    }

    func test_aRadioButtonTurnsTheWholeGroup() throws {
        let tab = try FormPdfs.tab()
        let second = try XCTUnwrap(FormPdfs.read(tab).find("plan")?.widgets[1])

        _ = try FormEdits.apply(tab, fonts, "Fill form field") { try $0.setValue("plan", second.export) }

        let plan = try XCTUnwrap(FormPdfs.read(tab).find("plan"))
        XCTAssertFalse(plan.widgets[0].isOn)
        XCTAssertTrue(plan.widgets[1].isOn)
    }

    func test_aListTakesSeveralChoices() throws {
        let tab = try FormPdfs.tab()

        _ = try FormEdits.apply(tab, fonts, "Fill form field") { try $0.setChoices("langs", ["English", "German"]) }

        XCTAssertEqual(FormPdfs.read(tab).find("langs")?.selected, ["English", "German"])
    }

    func test_aRequiredFieldReadsAsRequired() throws {
        let tab = try FormPdfs.tab()

        XCTAssertTrue(try XCTUnwrap(FormPdfs.read(tab).find("name")).has(.required))
        XCTAssertFalse(try XCTUnwrap(FormPdfs.read(tab).find("code")).has(.required))
    }

    func test_anEditOffTheMainActorIsCommittedOnceDone() async throws {
        let tab = try FormPdfs.tab()
        _ = try FormEdits.apply(tab, fonts, "Fill form field") { try $0.setValue("name", "Ada") }

        let reset = try await FormEdits.applyAsync(tab, fonts, "Reset form") { try $0.reset() }

        XCTAssertGreaterThan(reset, 0)
        XCTAssertEqual(tab.session.undoLabel, "Reset form")
        XCTAssertNil(FormPdfs.read(tab).find("name")?.value)
    }

    func test_flatteningTakesTheFieldsOut() throws {
        let tab = try FormPdfs.tab()
        _ = try FormEdits.apply(tab, fonts, "Fill form field") { try $0.setValue("name", "Ada") }

        let burned = try FormEdits.apply(tab, fonts, "Flatten form") { try $0.flatten() }

        XCTAssertEqual(burned, 7)
        XCTAssertTrue(FormPdfs.read(tab).fields.isEmpty)
        try tab.undo()
        XCTAssertEqual(FormPdfs.read(tab).fields.count, 6)
    }

    func test_aNewFieldGetsAFreeName() throws {
        let tab = try FormPdfs.tab()
        let form = FormPdfs.read(tab)

        XCTAssertEqual(FormEdits.newName(form, .text), "Text1")
        _ = try FormEdits.add(form, .text, 0, PdfRect(10, 10, 100, 30), nil)
        XCTAssertEqual(FormEdits.newName(FormPdfs.read(tab), .text), "Text2")
    }

    func test_aDrawnFieldIsAddedAsOneStep() throws {
        let tab = try FormPdfs.tab()

        let (name, widget) = try FormEdits.apply(tab, fonts, "Add form field") { try FormEdits.add($0, .checkBox, 1, PdfRect(20, 20, 34, 34), nil) }

        let field = try XCTUnwrap(FormPdfs.read(tab).find(name))
        XCTAssertEqual(widget, 0)
        XCTAssertEqual(field.kind, .checkBox)
        XCTAssertEqual(field.widgets[0].pageIndex, 1)
        try tab.undo()
        XCTAssertNil(FormPdfs.read(tab).find(name))
    }

    func test_aRadioButtonDrawnWhileAGroupIsSelectedJoinsIt() throws {
        let tab = try FormPdfs.tab()

        let (name, widget) = try FormEdits.apply(tab, fonts, "Add form field") {
            try FormEdits.add($0, .radio, 0, PdfRect(200, 550, 214, 564), $0.find("plan"))
        }

        XCTAssertEqual(name, "plan")
        XCTAssertEqual(widget, 2)
        XCTAssertEqual(FormPdfs.read(tab).find("plan")?.widgets.count, 3)
    }

    func test_aRadioButtonDrawnAloneStartsAGroup() throws {
        let tab = try FormPdfs.tab()

        let (name, _) = try FormEdits.apply(tab, fonts, "Add form field") { try FormEdits.add($0, .radio, 0, PdfRect(200, 500, 214, 514), nil) }

        XCTAssertEqual(name, "Radio1")
    }

    func test_aRadioGroupCanBeNamedWhenItIsMadeAndLaterButtonsJoinIt() throws {
        let tab = try FormPdfs.tab()

        let (first, _) = try FormEdits.apply(tab, fonts, "Add form field") {
            try FormEdits.add($0, .radio, 0, PdfRect(200, 500, 214, 514), nil, group: " size ")
        }
        let (second, widget) = try FormEdits.apply(tab, fonts, "Add form field") {
            try FormEdits.add($0, .radio, 0, PdfRect(240, 500, 254, 514), nil, group: "size")
        }

        XCTAssertEqual([first, second], ["size", "size"])
        XCTAssertEqual(widget, 1)
        XCTAssertEqual(FormPdfs.read(tab).find("size")?.widgets.map(\.onState), ["Choice1", "Choice2"])
    }

    func test_aGroupNameWinsOverTheSelectedGroupAndCannotTakeAnotherKindsName() throws {
        let tab = try FormPdfs.tab()

        let (name, _) = try FormEdits.apply(tab, fonts, "Add form field") {
            try FormEdits.add($0, .radio, 0, PdfRect(200, 500, 214, 514), $0.find("plan"), group: "other")
        }

        XCTAssertEqual(name, "other")
        XCTAssertEqual(FormPdfs.read(tab).find("plan")?.widgets.count, 2)
        XCTAssertThrowsError(try FormEdits.apply(tab, fonts, "Add form field") {
            try FormEdits.add($0, .radio, 0, PdfRect(200, 450, 214, 464), nil, group: "name")
        }) { XCTAssertTrue($0 is InvalidOperationException, "\($0)") }
    }

    func test_addressesAreWebOrMailAddresses() {
        let cases: [(String, String?)] = [
            ("example.com/form", "https://example.com/form"),
            (" http://example.com ", "http://example.com"),
            ("mailto:a@example.com", "mailto:a@example.com"),
            ("forms@acme.com", "mailto:forms@acme.com"),
            ("https://forms@acme.com", nil),
            ("two words", nil),
            ("", nil),
            ("javascript:alert(1)", nil),
        ]
        for (typed, expected) in cases {
            XCTAssertEqual(FormEdits.address(of: typed), expected, typed)
        }
    }

    func test_coloursAreComparedAsTheyShowOnScreen() {
        XCTAssertTrue(FormEdits.sameColour([0], [0, 0, 0]))
        XCTAssertTrue(FormEdits.sameColour([0.5], [0.5, 0.5, 0.5]))
        XCTAssertTrue(FormEdits.sameColour([0, 0, 0, 1], [0]))
        XCTAssertFalse(FormEdits.sameColour([0, 0, 1], [1, 0, 0]))
    }

    func test_lookAndActionAreOneUndoableStepEach() throws {
        let tab = try FormPdfs.tab()

        _ = try FormEdits.apply(tab, fonts, "Change font") { try $0.setFont(try XCTUnwrap($0.find("name")), "CoBo") }
        _ = try FormEdits.apply(tab, fonts, "Change button action") { form in
            let go = try form.addField(FieldSpec(.pushButton, "go", 0, PdfRect(300, 100, 400, 124), caption: "Go"))
            try form.setButtonAction(go, ButtonAction(.hide, "name"))
        }

        let form = FormPdfs.read(tab)
        XCTAssertEqual(form.getTextLook(try XCTUnwrap(form.find("name"))).font, "CoBo")
        let action = form.getButtonAction(try XCTUnwrap(form.find("go")))
        XCTAssertEqual(action.kind, .hide)
        XCTAssertEqual(action.target, "name")
        try tab.undo()
        XCTAssertNil(FormPdfs.read(tab).find("go"))
        try tab.undo()
        let back = FormPdfs.read(tab)
        XCTAssertEqual(back.getTextLook(try XCTUnwrap(back.find("name"))).font, "Helv")
    }

    func test_movingAndResizingAWidgetKeepsItsField() throws {
        let tab = try FormPdfs.tab()
        let rect = PdfRect(70, 650, 400, 700)

        _ = try FormEdits.apply(tab, fonts, "Move form field") { try $0.resize(try XCTUnwrap($0.find("code")).widgets[0], rect) }

        XCTAssertEqual(FormPdfs.read(tab).find("code")?.widgets[0].rect, rect)
    }

    func test_aTakenNameIsRefusedWithTheEnginesSentenceAndNothingIsCommitted() throws {
        let tab = try FormPdfs.tab()

        XCTAssertThrowsError(try FormEdits.apply(tab, fonts, "Rename field") { try $0.rename(try XCTUnwrap($0.find("code")), "name") }) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, FormText.nameTaken("name"))
            XCTAssertEqual(FormEdits.problem(of: error).text, FormText.nameTaken("name"))
        }
        XCTAssertFalse(tab.session.canUndo)
    }

    func test_aFlagAndTheOptionsAreChangedThroughTheEngine() throws {
        let tab = try FormPdfs.tab()

        _ = try FormEdits.apply(tab, fonts, "Change choices") { form in
            try form.setFlag(try XCTUnwrap(form.find("code")), .required, true)
            try form.setOptions(try XCTUnwrap(form.find("city")), FormEdits.parseOptions("Ankara\nIZ=Izmir\n\n Bursa "))
        }

        let read = FormPdfs.read(tab)
        XCTAssertTrue(try XCTUnwrap(read.find("code")).has(.required))
        XCTAssertEqual(read.find("city")?.options, [FieldOption("Ankara"), FieldOption("IZ", "Izmir"), FieldOption("Bursa")])
    }

    func test_optionsWriteBackAsTheyWereTyped() {
        let options = FormEdits.parseOptions("Ankara\r\nIZ=Izmir")

        XCTAssertEqual(FormEdits.formatOptions(options), "Ankara\r\nIZ=Izmir")
    }

    func test_removingOneRadioButtonLeavesTheGroup() throws {
        let tab = try FormPdfs.tab()

        _ = try FormEdits.apply(tab, fonts, "Delete form field") { try $0.remove(try XCTUnwrap($0.find("plan")).widgets[1]) }

        XCTAssertEqual(FormPdfs.read(tab).find("plan")?.widgets.count, 1)
    }

    func test_theTabOrderOfAPageIsSetAndRead() throws {
        let tab = try FormPdfs.tab()

        _ = try FormEdits.apply(tab, fonts, "Change tab order") { $0.setTabOrder(0, .row) }

        XCTAssertEqual(FormPdfs.read(tab).getTabOrder(0), .row)
    }

    func test_fillingAStaticXfaFormRemovesTheXfaData() throws {
        let tab = try FormPdfs.tab(try FormPdfs.staticXfa())
        XCTAssertEqual(FormPdfs.read(tab).xfa, .static)

        _ = try FormEdits.apply(tab, fonts, "Fill form field") { try $0.setValue("name", "Ada") }

        XCTAssertEqual(FormPdfs.read(tab).xfa, .none)
    }

    func test_aDynamicXfaFormCannotBeFilledAndSaysWhy() throws {
        let tab = try FormPdfs.tab(FormPdfs.dynamicXfa())
        XCTAssertEqual(FormPdfs.read(tab).xfa, .dynamic)

        XCTAssertThrowsError(try FormEdits.apply(tab, fonts, "Fill form field") { try $0.setValue("name", "Ada") }) { error in
            XCTAssertTrue(error is PdfReadException, "\(error)")
            XCTAssertEqual(FormEdits.problem(of: error).text, FormText.dynamicXfa)
        }
    }

    func test_detectingReadsACopyAndLeavesTheTabAlone() throws {
        let bytes = try PdfFromText.create("Name: ______________________\nCity: ______________________", fonts: fonts).bytes
        let tab = try FormPdfs.tab(bytes)

        let found = try FormEdits.detect(tab)

        XCTAssertFalse(tab.isDirty)
        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.allSatisfy { $0.pageIndex == 0 })
    }

    func test_aRefusedEditLeavesNothingPendingInTheDocument() throws {
        let tab = try FormPdfs.tab()

        XCTAssertThrowsError(try FormEdits.apply(tab, fonts, "Rename field") { form in
            try form.setFlag(try XCTUnwrap(form.find("code")), .required, true)
            try form.rename(try XCTUnwrap(form.find("code")), "name")
        })

        XCTAssertFalse(tab.isDirty)
        XCTAssertFalse(try XCTUnwrap(FormPdfs.read(tab).find("code")).has(.required))
        _ = try FormEdits.apply(tab, fonts, "Fill form field") { try $0.setValue("name", "Ada") }
        try tab.undo()
        XCTAssertFalse(try XCTUnwrap(FormPdfs.read(tab).find("code")).has(.required))
    }

    func test_anEditCancelledWhileItRanIsNotCommitted() async throws {
        let tab = try FormPdfs.tab()
        let token = CancelToken()

        do {
            _ = try await FormEdits.applyAsync(tab, fonts, "Reset form", token: token) { form in
                _ = try form.setValue("name", "Ada")
                token.cancel()
                return 1
            }
            XCTFail("The edit should have been cancelled.")
        } catch is CancellationError {}

        XCTAssertFalse(tab.isDirty)
        XCTAssertNil(FormPdfs.read(tab).find("name")?.value)
    }

    func test_anEditWhoseDocumentWasReplacedMeanwhileSaysSoAndKeepsTheNewOne() async throws {
        let tab = try FormPdfs.tab()
        _ = try FormEdits.apply(tab, fonts, "Fill form field") { try $0.setValue("name", "Ada") }
        let session = tab.session

        do {
            _ = try await FormEdits.applyAsync(tab, fonts, "Reset form") { form in
                _ = try session.undo()
                return try form.reset()
            }
            XCTFail("The edit should have been refused.")
        } catch let error as InvalidOperationException {
            XCTAssertEqual(error.message, L10n.t("The file changed meanwhile. Run it again."))
        }

        XCTAssertFalse(tab.session.canUndo)
        XCTAssertFalse(tab.isDirty)
    }

    func test_aFieldDrawnOnATurnedPageIsTurnedWithIt() throws {
        let tab = try FormPdfs.tab(try FormPdfs.turned())

        let (name, _) = try FormEdits.apply(tab, fonts, "Add form field") { try FormEdits.add($0, .text, 0, PdfRect(300, 100, 320, 250), nil) }

        let widget = try XCTUnwrap(FormPdfs.read(tab).find(name)?.widgets[0])
        let mk = try XCTUnwrap(tab.document.resolve(widget.dictionary["MK"]) as? PdfDictionary)
        XCTAssertEqual(tab.document.integer(mk, "R"), 90)
    }

    func test_foundFieldsTakeFreeNamesInsteadOfFailingHalfWay() throws {
        let tab = try FormPdfs.tab()
        let found = [
            FieldProposal(0, PdfRect(60, 300, 200, 320), .text, "fresh", nil),
            FieldProposal(0, PdfRect(60, 270, 200, 290), .text, "name", nil),
            FieldProposal(0, PdfRect(60, 240, 200, 260), .text, "name.first", nil),
        ]

        let added = try FormEdits.apply(tab, fonts, "Add form fields") { try FormEdits.addFound($0, found) }

        let form = FormPdfs.read(tab)
        XCTAssertEqual(added, 3)
        XCTAssertNotNil(form.find("fresh"))
        XCTAssertNotNil(form.find("name_2"))
        XCTAssertNotNil(form.find("name_first"))
    }

    func test_aButtonCaptionIsSetAndReadBack() throws {
        let tab = try FormPdfs.tab()
        _ = try FormEdits.apply(tab, fonts, "Add form field") { try FormEdits.add($0, .pushButton, 0, PdfRect(60, 300, 160, 324), nil) }

        _ = try FormEdits.apply(tab, fonts, "Change button caption") { try FormEdits.setCaption($0, try XCTUnwrap($0.find("Button1")), "Submit") }

        let form = FormPdfs.read(tab)
        XCTAssertEqual(FormEdits.caption(of: form, try XCTUnwrap(form.find("Button1"))), "Submit")
    }

    func test_changingFieldsNeedsPermissionToModifyTheFile() throws {
        let tab = try FormPdfs.tab()

        XCTAssertTrue(FormEdits.canModify(tab.document))
    }

    func test_findingFieldsEndsWhenTheJobIsCancelled() async throws {
        let token = CancelToken()
        token.cancel()

        do {
            _ = try await FormEdits.detect(Pdfs.text(2), password: nil, certificate: nil, renderer: FakeRenderer(), token: token)
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_aFormWithoutFieldsReadsAsEmpty() throws {
        let tab = try FormPdfs.tab(Pdfs.text())

        XCTAssertTrue(FormPdfs.read(tab).fields.isEmpty)
        XCTAssertEqual(FormPdfs.read(tab).xfa, .none)
    }
}
