import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The forms panel as the window drives it. Windows has no tests of FormsPanel, so these are written for the model: filling from
// the list and from the page, the signed-file question, the permissions, editing, form data files and flattening.

@MainActor
final class FormsModelTests: XCTestCase {
    func test_everyFieldIsInTheListWithItsKindAndPage() throws {
        let rig = try FormsRig()

        XCTAssertEqual(rig.model.rows.map(\.name), ["name", "code", "agree", "plan", "city", "langs"])
        XCTAssertEqual(rig.model.rows[0].detail, "Text field, page 1")
        XCTAssertEqual(rig.model.rows[3].kind, .radio)
        XCTAssertEqual(rig.model.rows[3].options.map(\.export), ["Choice1", "Choice2"])
        XCTAssertTrue(rig.model.rows[0].isRequired)
        XCTAssertEqual(rig.model.summary, "6 fields, 1 required")
        XCTAssertNil(rig.model.note)
    }

    func test_aFileWithoutFieldsSaysSoAndPointsToEditing() throws {
        let rig = try FormsRig(Pdfs.text())

        XCTAssertTrue(rig.model.rows.isEmpty)
        XCTAssertEqual(rig.model.summary, "This file has no form fields.")
        XCTAssertEqual(rig.model.note, "Choose Edit fields to add some, or to find the blanks of a form.")
        XCTAssertFalse(rig.model.action!.canRun())
    }

    func test_aDynamicXfaFormIsNotFilled() throws {
        let rig = try FormsRig(FormPdfs.dynamicXfa())

        XCTAssertFalse(rig.model.canFillForm)
        XCTAssertEqual(rig.model.note, FormText.dynamicXfa)
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_aTypedValueIsOneUndoableStepAndTheListFollows() throws {
        let rig = try FormsRig()

        rig.model.typeRow(rig.model.rows[0], "Ada")

        XCTAssertEqual(rig.form.find("name")?.value, "Ada")
        XCTAssertEqual(rig.model.rows[0].value, "Ada")
        XCTAssertEqual(rig.tab.session.undoLabel, "Fill form field")
        try rig.tab.undo()
        XCTAssertNil(rig.form.find("name")?.value)
    }

    func test_aValueTheFieldRefusesIsNotKeptAndSaysSo() throws {
        let rig = try FormsRig()

        XCTAssertFalse(rig.model.enter("city", "Nowhere"))

        XCTAssertEqual(rig.host.problems.map(\.title), ["Value not accepted"])
        XCTAssertNil(rig.form.find("city")?.value)
    }

    func test_aListThatTakesOneChoiceReplacesItAndOneThatTakesSeveralKeepsTheRest() throws {
        let rig = try FormsRig()
        try rig.change("Add form field") { form in
            try form.addField(FieldSpec(.listBox, "size", 0, PdfRect(300, 420, 400, 490), options: [FieldOption("A"), FieldOption("B"), FieldOption("C")]))
        }
        func row(_ name: String) throws -> FieldRow { try XCTUnwrap(rig.model.rows.first { $0.name == name }) }
        XCTAssertFalse(try row("size").multiSelect)
        rig.model.setChoice(try row("size"), FieldOption("B"), true)
        rig.model.setChoice(try row("size"), FieldOption("C"), true)
        XCTAssertEqual(rig.form.find("size")?.selected, ["C"])

        XCTAssertTrue(try row("langs").multiSelect)
        rig.model.setChoice(try row("langs"), FieldOption("English"), true)
        rig.model.setChoice(try row("langs"), FieldOption("German"), true)
        XCTAssertEqual(rig.form.find("langs")?.selected, ["English", "German"])
        rig.model.setChoice(try row("langs"), FieldOption("English"), false)
        XCTAssertEqual(rig.form.find("langs")?.selected, ["German"])
    }

    func test_aFreeValueIsTypedIntoAnEditableDropDownAndShownInItsRow() throws {
        let rig = try FormsRig()
        try rig.change("Change typing in the list") { try $0.setFlag(try XCTUnwrap($0.find("city")), .edit, true) }
        let city = try XCTUnwrap(rig.model.rows.first { $0.name == "city" })
        XCTAssertTrue(city.isEditable)

        rig.model.typeRow(city, "Bursa")

        XCTAssertEqual(rig.form.find("city")?.value, "Bursa")
        XCTAssertEqual(rig.model.rows.first { $0.name == "city" }?.value, "Bursa")
    }

    func test_aFieldsHintIsItsLabelWhenItHasOne() throws {
        let rig = try FormsRig()
        XCTAssertEqual(rig.model.rows[0].label, "name")
        try rig.change("Change field hint") { $0.setTooltip(try XCTUnwrap($0.find("name")), "Date of birth") }

        let row = rig.model.rows[0]

        XCTAssertEqual(row.label, "Date of birth")
        XCTAssertEqual(row.summary, "Date of birth, Text field, page 1")
        XCTAssertEqual(row.name, "name")
    }

    func test_aTapOnAListOnThePageSaysWhereItsChoicesAre() throws {
        let rig = try FormsRig()

        rig.tap(rig.centre("langs"))

        XCTAssertEqual(rig.host.statuses.last, "Choose a value for langs in the panel.")
    }

    func test_aCheckBoxAndAChoiceAreSetFromTheirRows() throws {
        let rig = try FormsRig()

        rig.model.toggleRow(rig.model.rows[2])
        rig.model.chooseRow(rig.model.rows[4], "IZ")
        rig.model.chooseRow(rig.model.rows[5], many: ["English", "German"])
        rig.model.chooseRow(rig.model.rows[3], "Choice2")

        let form = rig.form
        XCTAssertEqual(form.find("agree")?.isChecked, true)
        XCTAssertTrue(rig.model.rows[2].isOn)
        XCTAssertEqual(form.find("city")?.value, "IZ")
        XCTAssertEqual(form.find("langs")?.selected, ["English", "German"])
        XCTAssertEqual(form.find("plan")?.widgets[1].isOn, true)
        rig.model.toggleRow(rig.model.rows[2])
        XCTAssertEqual(rig.form.find("agree")?.isChecked, false)
    }

    func test_aSignedFileAsksBeforeTheFirstChangeAndThenMakesIt() throws {
        let rig = try FormsRig(FormPdfs.signedForm())

        rig.model.typeRow(rig.model.rows[0], "Ada")

        XCTAssertNil(rig.form.find("name")?.value)
        XCTAssertEqual(rig.host.notices.map(\.title), ["File is signed"])
        rig.host.notices[0].action?.run()
        XCTAssertEqual(rig.form.find("name")?.value, "Ada")
        rig.model.typeRow(rig.model.rows[1], "12")
        XCTAssertEqual(rig.host.notices.count, 1)
        XCTAssertEqual(rig.form.find("code")?.value, "12")
    }

    func test_handingInStaysFalseWhileTheSignedQuestionWaitsForItsAnswer() throws {
        let rig = try FormsRig(FormPdfs.signedForm())
        rig.tap(rig.centre("name"))
        try XCTUnwrap(rig.field("name")).typed("Ada")

        XCTAssertFalse(rig.model.handIn())
        XCTAssertFalse(rig.model.handIn())
        rig.host.notices[0].action?.run()

        XCTAssertEqual(rig.form.find("name")?.value, "Ada")
        XCTAssertTrue(rig.model.handIn())
    }

    func test_handingInGoesOnOnceTheSignedQuestionIsDismissed() throws {
        let rig = try FormsRig(FormPdfs.signedForm())
        rig.tap(rig.centre("name"))
        try XCTUnwrap(rig.field("name")).typed("Ada")
        XCTAssertFalse(rig.model.handIn())

        rig.host.noticeWaits = false

        XCTAssertTrue(rig.model.handIn())
    }

    func test_handingInReportsAPendingSignedQuestion() throws {
        let rig = try FormsRig(FormPdfs.signedForm())
        rig.tap(rig.centre("name"))
        let field = try XCTUnwrap(rig.field("name"))
        field.typed("Ada")

        XCTAssertFalse(rig.model.handIn())

        XCTAssertEqual(rig.host.notices.count, 1)
        XCTAssertNil(rig.form.find("name")?.value)
    }

    func test_aFileThatForbidsFillingCannotBeFilledOrEdited() throws {
        let rig = try FormsRig(FormPdfs.printOnly(), password: "")

        XCTAssertFalse(rig.model.canFillForm)
        XCTAssertFalse(rig.model.canEdit)
        XCTAssertEqual(rig.model.note, "The permissions of this file do not allow filling in forms.")
        XCTAssertFalse(rig.model.action!.canRun())
        XCTAssertNil(rig.viewer.pointerTool)
        XCTAssertFalse(rig.model.rows.contains { $0.canFill })
    }

    func test_aFileThatForbidsModifyingKeepsFillingButNotEditing() throws {
        let document = try PdfDocument.open(FormPdfs.standard())
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: [.print, .fillForms], strength: .aes256,
                                          firstId: [UInt8](repeating: 7, count: 16))
        let rig = try FormsRig(try document.saveRewrite(PdfSaveOptions(security: security)), password: "")

        XCTAssertTrue(rig.model.canFillForm)
        XCTAssertFalse(rig.model.canEdit)
        rig.model.setDesigning(true)
        XCTAssertEqual(rig.model.note, "The permissions of this file do not allow changing its fields.")
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_flatteningTakesTheFieldsOutAndCanBeUndone() async throws {
        let rig = try FormsRig()
        rig.model.typeRow(rig.model.rows[0], "Ada")

        await rig.model.action!.run()

        XCTAssertTrue(rig.form.fields.isEmpty)
        XCTAssertEqual(rig.host.statuses.last, "7 fields flattened.")
        XCTAssertTrue(rig.model.rows.isEmpty)
        try rig.tab.undo()
        XCTAssertEqual(rig.form.fields.count, 6)
    }

    func test_resettingTheFormClearsTheValues() async throws {
        let rig = try FormsRig()
        rig.model.typeRow(rig.model.rows[0], "Ada")

        await rig.model.resetForm()

        XCTAssertNil(rig.form.find("name")?.value)
        XCTAssertEqual(rig.tab.session.undoLabel, "Reset form")
        XCTAssertTrue(rig.host.statuses.last?.hasSuffix("reset.") == true)
    }

    func test_theFileChangingElsewhereIsFollowed() async throws {
        let rig = try FormsRig()

        _ = try FormEdits.apply(rig.tab, FormPdfs.fonts, "Fill form field") { try $0.setValue("name", "Grace") }
        await waitUntil { rig.model.rows[0].value == "Grace" }

        XCTAssertEqual(rig.model.rows[0].value, "Grace")
    }

    func test_exportedDataGoesThroughTheExporterUnderTheFilesName() async throws {
        let rig = try FormsRig()
        rig.model.typeRow(rig.model.rows[0], "Ada")
        rig.model.dataFormat = .csv

        await rig.model.exportData()

        XCTAssertEqual(rig.host.picker.exported.map(\.name), ["form.csv"])
        XCTAssertTrue(String(decoding: rig.host.picker.exported[0].bytes.dropFirst(3), as: UTF8.self).hasPrefix("name,code,"))
        XCTAssertEqual(rig.host.statuses.last, "Form data exported.")
    }

    func test_importedDataFillsTheFormAndReportsWhatItDidNotUse() async throws {
        let rig = try FormsRig()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("data-\(UUID().uuidString).csv")
        try Data("name;nothing\r\nAda;x\r\nGrace;y\r\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.host.picker.picked = [ToolFile(url: url)]

        await rig.model.importData()

        XCTAssertEqual(rig.form.find("name")?.value, "Ada")
        XCTAssertEqual(rig.host.statuses.last, "1 field filled.")
        let notice = try XCTUnwrap(rig.host.notices.last)
        XCTAssertEqual(notice.title, "Some data was not used")
        XCTAssertTrue(notice.text.contains("nothing"))
        XCTAssertTrue(notice.text.contains("The file has 2 rows. Only the first was used."))
        XCTAssertEqual(rig.tab.session.undoLabel, "Import form data")
    }

    func test_aDataFileOfAnUnknownTypeIsRefused() async throws {
        let rig = try FormsRig()
        rig.host.picker.picked = [ToolFile(url: URL(fileURLWithPath: "/tmp/notes.txt"))]

        await rig.model.importData()

        XCTAssertEqual(rig.host.problems.map(\.title), ["Unknown data file"])
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_aDataFileThatIsNotFormDataLeavesTheFileAlone() async throws {
        let rig = try FormsRig()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("data-\(UUID().uuidString).json")
        try Data("[1, 2]".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        rig.host.picker.picked = [ToolFile(url: url)]

        await rig.model.importData()

        XCTAssertEqual(rig.host.problems.map(\.title), ["Data not read"])
        XCTAssertFalse(rig.tab.isDirty)
    }

    func test_nothingPickedChangesNothing() async throws {
        let rig = try FormsRig()

        await rig.model.importData()

        XCTAssertTrue(rig.host.problems.isEmpty)
        XCTAssertFalse(rig.tab.isDirty)
    }

    private func designing(_ bytes: [UInt8]? = nil) throws -> FormsRig {
        let rig = try FormsRig(bytes)
        rig.model.setDesigning(true)
        return rig
    }

    func test_theCardIsWrittenWhenThePanelIsHandedIn() throws {
        let rig = try designing()
        rig.model.select("code", 0)
        rig.model.hintDraft = "Four digits"
        rig.model.cardFocus = .hint

        XCTAssertTrue(rig.model.handIn())

        XCTAssertEqual(rig.form.find("code")?.tooltip, "Four digits")
        XCTAssertEqual(rig.tab.session.undoLabel, "Change field hint")
    }

    func test_theCardIsWrittenBeforeAnotherFieldIsSelected() throws {
        let rig = try designing()
        rig.model.select("code", 0)
        rig.model.hintDraft = "Four digits"
        rig.model.cardFocus = .hint

        rig.model.select("name", 0)

        XCTAssertEqual(rig.form.find("code")?.tooltip, "Four digits")
        XCTAssertEqual(rig.model.hintDraft, "")
        XCTAssertEqual(rig.model.selected, "name")
    }

    func test_theCardIsWrittenBeforeFillingComesBack() throws {
        let rig = try designing()
        rig.model.select("code", 0)
        rig.model.hintDraft = "Four digits"
        rig.model.cardFocus = .hint

        rig.model.setDesigning(false)

        XCTAssertEqual(rig.form.find("code")?.tooltip, "Four digits")
        XCTAssertFalse(rig.model.designing)
    }

    func test_aFieldBeingTypedInIsInTheFileBeforeItIsExportedResetOrLeftForEditing() async throws {
        let rig = try FormsRig()
        rig.tap(rig.centre("name"))
        try XCTUnwrap(rig.field("name")).typed("Ada")

        await rig.model.exportData()

        let text = String(decoding: try XCTUnwrap(rig.host.picker.exported.first).bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("Ada"))

        rig.tap(rig.centre("code"))
        try XCTUnwrap(rig.field("code")).typed("12")
        await rig.model.resetForm()
        XCTAssertNil(rig.form.find("code")?.value)
        XCTAssertNil(rig.form.find("name")?.value)

        rig.tap(rig.centre("code"))
        try XCTUnwrap(rig.field("code")).typed("34")
        rig.model.setDesigning(true)
        XCTAssertEqual(rig.form.find("code")?.value, "34")
        XCTAssertNil(rig.field("code"))
    }

    func test_editingTakesThePointerAndFillingGivesItBack() throws {
        let rig = try FormsRig()
        let fill = rig.viewer.pointerTool

        rig.model.setDesigning(true)
        XCTAssertNotNil(rig.viewer.pointerTool)
        XCTAssertFalse(rig.viewer.pointerTool === fill)
        rig.model.setDesigning(false)

        XCTAssertTrue(rig.viewer.pointerTool != nil)
        rig.model.detach()
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_choosingAnotherPointerWhileEditingGoesBackToFilling() async throws {
        let rig = try designing()

        rig.viewer.pointerTool = nil
        await waitUntil { !rig.model.designing }

        XCTAssertFalse(rig.model.designing)
    }

    func test_selectingAFieldFillsTheCard() throws {
        let rig = try designing()

        rig.model.select("code", 0)

        XCTAssertEqual(rig.model.cardKind, .text)
        XCTAssertEqual(rig.model.nameDraft, "code")
        XCTAssertEqual(rig.model.lengthDraft, "4")
        XCTAssertEqual(rig.model.fontName, "Helv")
        XCTAssertEqual(rig.model.colourIndex, 0)
    }

    func test_theCardWritesAPropertyAsOneStepEach() throws {
        let rig = try designing()
        rig.model.select("code", 0)

        rig.model.nameDraft = "zip"
        rig.model.commit(.name)
        rig.model.hintDraft = "Postcode"
        rig.model.commit(.hint)
        rig.model.lengthDraft = "6"
        rig.model.commit(.length)
        rig.model.setFlag(.required, true)

        let zip = try XCTUnwrap(rig.form.find("zip"))
        XCTAssertNil(rig.form.find("code"))
        XCTAssertEqual(zip.tooltip, "Postcode")
        XCTAssertEqual(zip.maxLength, 6)
        XCTAssertTrue(zip.has(.required))
        XCTAssertEqual(rig.model.selected, "zip")
        XCTAssertEqual(rig.tab.session.undoLabel, "Change required")
    }

    func test_aNameTheFormAlreadyHasIsRefusedAndTheCardGoesBack() throws {
        let rig = try designing()
        rig.model.select("code", 0)

        rig.model.nameDraft = "name"
        rig.model.commit(.name)

        XCTAssertEqual(rig.host.problems.last?.text, FormText.nameTaken("name"))
        XCTAssertEqual(rig.model.nameDraft, "code")
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_anEmptyNameAndALongestTextThatIsNotANumberAreRefused() throws {
        let rig = try designing()
        rig.model.select("code", 0)

        rig.model.nameDraft = "  "
        rig.model.commit(.name)
        rig.model.lengthDraft = "4x"
        rig.model.commit(.length)

        XCTAssertEqual(rig.host.problems.map(\.title), ["Field not changed", "Longest text not a number"])
        XCTAssertFalse(rig.tab.session.canUndo)
        XCTAssertEqual(rig.model.lengthDraft, "4")
    }

    func test_theChoicesOfAListAreTypedOnePerLine() throws {
        let rig = try designing()
        rig.model.select("city", 0)
        XCTAssertEqual(rig.model.choicesDraft, "Ankara\r\nIZ=Izmir")

        rig.model.choicesDraft = "Ankara\nBursa\nIZ=Izmir"
        rig.model.commit(.choices)

        XCTAssertEqual(rig.form.find("city")?.options.map(\.export), ["Ankara", "Bursa", "IZ"])
    }

    func test_aButtonTakesAnActionAndAnAddressThatIsChecked() async throws {
        let rig = try designing()
        _ = try FormEdits.apply(rig.tab, FormPdfs.fonts, "Add form field") { try FormEdits.add($0, .pushButton, 0, PdfRect(300, 100, 400, 124), nil) }
        await waitUntil { rig.model.rows.count == 7 }
        rig.model.select("Button1", 0)

        rig.model.chooseAction(.openLink)
        XCTAssertEqual(rig.form.getButtonAction(try XCTUnwrap(rig.form.find("Button1"))).kind, ButtonActionKind.none)
        rig.model.targetDraft = "two words"
        rig.model.commit(.target)
        XCTAssertEqual(rig.host.problems.last?.title, "Address not accepted")
        rig.model.chooseAction(.openLink)
        rig.model.targetDraft = "example.com"
        rig.model.commit(.target)

        let action = rig.form.getButtonAction(try XCTUnwrap(rig.form.find("Button1")))
        XCTAssertEqual(action.kind, .openLink)
        XCTAssertEqual(action.target, "https://example.com")
    }

    func test_aFontAColourAndASizeAreSetFromTheCard() throws {
        let rig = try designing()
        rig.model.select("name", 0)

        rig.model.setFont("CoBo")
        rig.model.setColour(1)
        rig.model.sizeDraft = "14"
        rig.model.commit(.size)

        let look = rig.form.getTextLook(try XCTUnwrap(rig.form.find("name")))
        XCTAssertEqual(look.font, "CoBo")
        XCTAssertEqual(look.size, 14)
        XCTAssertTrue(FormEdits.sameColour(look.color, [0, 0, 1]))
        rig.model.sizeDraft = "300"
        rig.model.commit(.size)
        XCTAssertEqual(rig.host.problems.last?.title, "Text size not accepted")
    }

    func test_deletingARadioButtonLeavesTheGroupAndTheLastOneTakesTheField() throws {
        let rig = try designing()
        rig.model.select("plan", 1)

        rig.model.deleteSelected()
        XCTAssertEqual(rig.form.find("plan")?.widgets.count, 1)
        XCTAssertNil(rig.model.selected)
        rig.model.select("plan", 0)
        rig.model.deleteSelected()

        XCTAssertNil(rig.form.find("plan"))
    }

    func test_theTabOrderOfThePageIsShownAndSet() throws {
        let rig = try designing()
        XCTAssertEqual(rig.model.tabOrder, .annotations)

        rig.model.setTabOrder(.column)

        XCTAssertEqual(rig.form.getTabOrder(0), .column)
        XCTAssertEqual(rig.model.tabOrder, .column)
    }

    func test_proposalsForAPageThatWentAreDroppedAndNotAdded() throws {
        let rig = try designing()
        let late = FieldProposal(5, PdfRect(60, 300, 200, 320), .text, "late", nil)
        rig.model.found = [FoundRow(proposal: late)]
        rig.model.foundShown = true

        rig.model.reload()

        XCTAssertTrue(rig.model.found.isEmpty)
        XCTAssertFalse(rig.model.foundShown)
        XCTAssertThrowsError(try FormEdits.addFound(rig.form, [late])) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_blanksAreFoundAndTheCheckedOnesAdded() async throws {
        let bytes = try PdfFromText.create("Name: ______________________\nCity: ______________________", fonts: FormPdfs.fonts).bytes
        let rig = try designing(bytes)

        await rig.model.findFields()

        XCTAssertTrue(rig.model.foundShown)
        XCTAssertFalse(rig.model.found.isEmpty)
        XCTAssertTrue(rig.model.foundText.hasSuffix("found."))
        let count = rig.model.found.count
        rig.model.setFound(rig.model.found[0].id, false)
        rig.model.addFound()
        XCTAssertEqual(rig.form.fields.count, count - 1)
        XCTAssertFalse(rig.model.foundShown)
        XCTAssertEqual(rig.tab.session.undoLabel, "Add form fields")
    }
}
