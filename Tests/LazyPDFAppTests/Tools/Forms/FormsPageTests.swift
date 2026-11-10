import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The forms panel on the page: the fields a tap opens or turns, the pointer that fills them, and the pointer that draws, moves and
// resizes them. The stand-in viewer lays pages out 612 by 792 as the file is, with a scale of 1.

@MainActor
final class FormsFillOnThePageTests: XCTestCase {
    private func marks(_ rig: FormsRig, page: Int = 0) -> [OverlayItem] {
        rig.viewer.overlay(page).items.filter { $0.id.hasPrefix("forms.fill.") }
    }

    func test_aTapOnACheckBoxTurnsItOnAndAgainOff() throws {
        let rig = try FormsRig()

        rig.tap(rig.centre("agree"))
        XCTAssertEqual(rig.form.find("agree")?.isChecked, true)
        rig.tap(rig.centre("agree"))

        XCTAssertEqual(rig.form.find("agree")?.isChecked, false)
        XCTAssertEqual(rig.tab.session.undoLabel, "Fill form field")
    }

    func test_aTapOnARadioButtonChoosesItAndTheGroupFollows() throws {
        let rig = try FormsRig()

        rig.tap(rig.centre("plan", 1))

        let plan = try XCTUnwrap(rig.form.find("plan"))
        XCTAssertTrue(plan.widgets[1].isOn)
        XCTAssertFalse(plan.widgets[0].isOn)
    }

    func test_aFingerIsTheToolsOnlyOverAFieldAndScrollsElsewhere() throws {
        let rig = try FormsRig()
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        XCTAssertTrue(tool.takes(rig.pointer(rig.centre("name"), pressed: true)))
        XCTAssertTrue(tool.takes(rig.pointer(rig.centre("agree"), pressed: true)))
        XCTAssertFalse(tool.takes(rig.pointer(ViewPoint(400, 40), pressed: true)))
        XCTAssertFalse(tool.takes(rig.pointer(ViewPoint(400, 300), pressed: true)))
    }

    func test_aMousePressOffAFieldFallsThroughToTheViewer() throws {
        let tab = DocumentTab(session: try PdfEditSession.open(try FormPdfs.standard()), renderer: FakeRenderer(), url: nil,
                              title: "form.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 150), pixelsPerDip: 1)
        viewer.show(tab)
        viewer.mode = .hand
        viewer.zoom = 1
        let model = FormsModel(fonts: FormPdfs.fonts)
        model.attach(tab, viewer, FormsHost())
        XCTAssertNotNil(viewer.pointerTool)

        viewer.pointerDown(ViewPoint(480, 100))
        viewer.pointerMove(ViewPoint(480, 50))
        viewer.pointerUp(ViewPoint(480, 50))

        XCTAssertEqual(viewer.offset.y, 50, accuracy: 1)
        model.detach()
    }

    func test_aFingerBetweenCloseFieldsScrollsInsteadOfTakingEither() throws {
        let rig = try FormsRig()
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        // The text fields run 640 to 660 and 610 to 630: this is 5 points from each, well inside the reach of a fingertip.
        XCTAssertFalse(tool.takes(rig.pointer(ViewPoint(100, 792 - 635), pressed: true)))
        XCTAssertTrue(tool.takes(rig.pointer(ViewPoint(100, 792 - 650), pressed: true)))
    }

    func test_aSmallFieldIsHitByAFingerThatMissesItALittle() throws {
        let rig = try FormsRig()
        let box = rig.centre("agree")

        XCTAssertTrue(try XCTUnwrap(rig.viewer.pointerTool).takes(rig.pointer(ViewPoint(box.x + 20, box.y), pressed: true)))
        XCTAssertFalse(try XCTUnwrap(rig.viewer.pointerTool).takes(rig.pointer(ViewPoint(box.x + 200, box.y), pressed: true)))
    }

    func test_aPressThatLeavesTheFieldBeforeItIsReleasedDoesNothing() throws {
        let rig = try FormsRig()
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        tool.press(rig.pointer(rig.centre("agree"), pressed: true))
        tool.release(rig.pointer(ViewPoint(400, 40), pressed: false))

        XCTAssertEqual(rig.form.find("agree")?.isChecked, false)
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_aRowOfThePanelHandsInTheFieldBeingTypedInBeforeItOpensAgain() throws {
        let rig = try FormsRig()
        rig.tap(rig.centre("name"))
        try XCTUnwrap(rig.field("name")).typed("Ada")

        rig.model.focusRow(rig.model.rows[0])

        XCTAssertEqual(rig.form.find("name")?.value, "Ada")
        XCTAssertEqual(rig.field("name")?.text, "Ada")
        XCTAssertEqual(rig.tab.session.undoLabel, "Fill form field")
    }

    func test_aFlagsValueBeyondTheRangeOfAnIntegerDoesNotStopTheFieldsShowing() throws {
        let rig = try FormsRig()

        try rig.change("Change") { form in
            let widget = try XCTUnwrap(form.find("name")).widgets[0]
            widget.dictionary["F"] = PdfNumber("99999999999999999999")
        }

        XCTAssertTrue(try XCTUnwrap(rig.viewer.pointerTool).takes(rig.pointer(rig.centre("name"), pressed: true)))
    }

    func test_nothingOnThePageIsTheToolsWhileAnEditRuns() throws {
        let rig = try FormsRig()
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        rig.model.isWorking = true
        XCTAssertFalse(tool.takes(rig.pointer(rig.centre("name"), pressed: true)))
        rig.model.focusRow(rig.model.rows[0])
        XCTAssertNil(rig.field("name"))
        rig.model.isWorking = false

        XCTAssertTrue(tool.takes(rig.pointer(rig.centre("name"), pressed: true)))
    }

    func test_aDocumentSwappedWithoutAChangeIsReadAgain() throws {
        let rig = try FormsRig()
        let before = try XCTUnwrap(rig.model.fillHit(0, rig.centre("name")))

        try rig.tab.session.discard()
        rig.model.afterEdit()

        let after = try XCTUnwrap(rig.model.fillHit(0, rig.centre("name")))
        XCTAssertFalse(before.dictionary === after.dictionary)
        XCTAssertTrue(after.dictionary === rig.form.find("name")?.widgets[0].dictionary)
    }

    func test_aPointerChosenFromTheToolbarDoesNotTakeTheFieldsAway() async throws {
        let rig = try FormsRig()

        rig.viewer.pointerTool = nil
        await waitUntil { rig.viewer.pointerTool != nil }

        XCTAssertTrue(try XCTUnwrap(rig.viewer.pointerTool).takes(rig.pointer(rig.centre("name"), pressed: true)))
    }

    func test_aTapOnATextFieldOpensItWithItsLimitsAndTheTextIsKeptWhenItEnds() throws {
        let rig = try FormsRig()

        rig.tap(rig.centre("code"))
        let field = try XCTUnwrap(rig.field("code"))

        XCTAssertEqual(field.maxLength, 4)
        XCTAssertFalse(field.secure)
        XCTAssertFalse(field.multiline)
        XCTAssertEqual(field.label, "code")
        field.commit("1234")
        XCTAssertEqual(rig.form.find("code")?.value, "1234")
        XCTAssertNil(rig.field("code"))
    }

    func test_escapeLeavesTheTextAsItWas() throws {
        let rig = try FormsRig()
        rig.tap(rig.centre("name"))

        let field = try XCTUnwrap(rig.field("name"))
        field.typed("Ada")
        field.drop()

        XCTAssertNil(rig.form.find("name")?.value)
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_aPasswordFieldShowsDotsAndAMultilineOneWraps() throws {
        let rig = try FormsRig()
        try rig.change("Change") { form in
            try form.setFlag(try XCTUnwrap(form.find("name")), .password, true)
            try form.setFlag(try XCTUnwrap(form.find("code")), .multiline, true)
        }
        rig.tap(rig.centre("name"))
        XCTAssertEqual(rig.field("name")?.secure, true)
        rig.field("name")?.drop()

        rig.tap(rig.centre("code"))

        XCTAssertEqual(rig.field("code")?.multiline, true)
        XCTAssertEqual(rig.field("code")?.wraps, true)
    }

    func test_tabFinishesTheFieldAndOpensTheNextOneAndShiftTabGoesBack() throws {
        let rig = try FormsRig()
        rig.tap(rig.centre("name"))
        let name = try XCTUnwrap(rig.field("name"))
        name.typed("Ada")

        name.onTab?(false)

        XCTAssertEqual(rig.form.find("name")?.value, "Ada")
        XCTAssertNil(rig.field("name"))
        let code = try XCTUnwrap(rig.field("code"))
        code.onTab?(true)
        XCTAssertNotNil(rig.field("name"))
        XCTAssertNil(rig.field("code"))
    }

    func test_tabAtTheLastFieldOfAPageGoesToTheFirstOneOfTheNextPage() throws {
        let rig = try FormsRig()
        try rig.change("Add form field") { try FormEdits.add($0, .text, 1, PdfRect(50, 400, 150, 420), nil) }
        rig.tap(rig.centre("code"))

        try XCTUnwrap(rig.field("code")).onTab?(false)

        XCTAssertNotNil(rig.field("Text1", page: 1))
        XCTAssertEqual(rig.viewer.revealed.last?.page, 1)
        XCTAssertNil(rig.field("code"))
    }

    func test_tabAtTheLastFieldOfTheFileJustFinishesIt() throws {
        let rig = try FormsRig()
        rig.tap(rig.centre("code"))

        try XCTUnwrap(rig.field("code")).onTab?(false)

        XCTAssertNil(rig.field("code"))
        XCTAssertTrue(rig.viewer.overlay(0).fields.isEmpty)
    }

    func test_aReadOnlyFieldIsNotTheTools() throws {
        let rig = try FormsRig()
        try rig.change("Change read only") { try $0.setFlag(try XCTUnwrap($0.find("name")), .readOnly, true) }
        rig.model.reload()

        XCTAssertFalse(try XCTUnwrap(rig.viewer.pointerTool).takes(rig.pointer(rig.centre("name"), pressed: true)))
        XCTAssertFalse(rig.model.rows[0].canFill)
    }

    func test_aRequiredEmptyFieldIsOutlinedInRedAndTheHighlightCanBeTurnedOff() throws {
        let rig = try FormsRig()

        XCTAssertEqual(marks(rig).count, 7)
        let required = try XCTUnwrap(marks(rig).first { $0.style.stroke != nil })
        XCTAssertEqual(required.style.stroke?.red ?? 0, 0xD1 / 255.0, accuracy: 0.001)

        rig.model.setHighlight(false)

        XCTAssertEqual(marks(rig).count, 1)
        rig.model.typeRow(rig.model.rows[0], "Ada")
        XCTAssertTrue(marks(rig).isEmpty)
    }

    func test_aTapOnAnEmptySignatureFieldOpensSigning() throws {
        let rig = try FormsRig()
        try rig.change("Add form field") { try FormEdits.add($0, .signature, 0, PdfRect(300, 300, 480, 340), nil) }

        rig.tap(rig.centre("Signature1"))

        XCTAssertEqual(rig.host.signing, ["Signature1"])
    }

    func test_aResetButtonOnThePageClearsTheFields() throws {
        let rig = try FormsRig()
        rig.model.typeRow(rig.model.rows[0], "Ada")
        try rig.change("Add form field") { form in
            let (name, _) = try FormEdits.add(form, .pushButton, 0, PdfRect(300, 300, 400, 324), nil)
            try form.setButtonAction(try XCTUnwrap(form.find(name)), ButtonAction(.reset))
        }

        rig.tap(rig.centre("Button1"))

        XCTAssertNil(rig.form.find("name")?.value)
        XCTAssertEqual(rig.tab.session.undoLabel, "Reset form")
    }

    func test_aTapOnADropDownOrAListShowsItsChoicesInThePanel() throws {
        let rig = try FormsRig()

        rig.tap(rig.centre("city"))

        XCTAssertEqual(rig.model.activeRow, rig.model.rows[4].id)
        rig.tap(rig.centre("langs"))
        XCTAssertEqual(rig.model.activeRow, rig.model.rows[5].id)
    }

    func test_typingIsHandedInBeforeASaveOrAnUndo() throws {
        let rig = try FormsRig()
        rig.tap(rig.centre("name"))
        try XCTUnwrap(rig.field("name")).typed("Grace")

        XCTAssertTrue(rig.model.handIn())

        XCTAssertEqual(rig.form.find("name")?.value, "Grace")
        XCTAssertNil(rig.field("name"))
    }

    func test_leavingThePanelKeepsWhatWasTypedAndTakesTheMarksOff() throws {
        let rig = try FormsRig()
        rig.tap(rig.centre("name"))
        try XCTUnwrap(rig.field("name")).typed("Grace")

        rig.viewer.endToolMarks(prefix: "forms.")
        rig.model.detach()

        XCTAssertEqual(rig.form.find("name")?.value, "Grace")
        XCTAssertTrue(rig.viewer.overlay(0).items.isEmpty)
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_marksFollowThePagesInView() async throws {
        let rig = try FormsRig()
        try rig.change("Add form field") { try FormEdits.add($0, .checkBox, 1, PdfRect(20, 20, 34, 34), nil) }
        await waitUntil { rig.model.rows.count == 7 }
        XCTAssertTrue(marks(rig, page: 1).isEmpty)

        rig.viewer.pageIndex = 1
        await waitUntil { !self.marks(rig, page: 1).isEmpty }

        XCTAssertTrue(marks(rig).isEmpty)
    }
}

@MainActor
final class FormsDesignOnThePageTests: XCTestCase {
    private func designing() throws -> FormsRig {
        let rig = try FormsRig()
        rig.model.setDesigning(true)
        return rig
    }

    private func frames(_ rig: FormsRig, page: Int = 0) -> [OverlayItem] {
        rig.viewer.overlay(page).items.filter { $0.id.hasPrefix("forms.frame.") }
    }

    func test_everyFieldIsOutlinedAndTheSelectedOneHasEightHandles() throws {
        let rig = try designing()
        XCTAssertEqual(frames(rig).count, 7)

        rig.model.select("name", 0)

        XCTAssertEqual(frames(rig).count, 15)
        let handles = frames(rig).filter { if case .marker = $0.shape { return true } else { return false } }
        XCTAssertEqual(handles.count, 8)
    }

    func test_aDragOnAnEmptyPlaceDrawsTheChosenKind() throws {
        let rig = try designing()
        rig.model.newKind = .text

        rig.drag(from: ViewPoint(100, 300), to: ViewPoint(250, 320))

        let widget = try XCTUnwrap(rig.form.find("Text1")?.widgets[0])
        XCTAssertEqual(widget.rect.left, 100, accuracy: 0.01)
        XCTAssertEqual(widget.rect.right, 250, accuracy: 0.01)
        XCTAssertEqual(widget.rect.bottom, 792 - 320, accuracy: 0.01)
        XCTAssertEqual(widget.rect.top, 792 - 300, accuracy: 0.01)
        XCTAssertEqual(rig.model.selected, "Text1")
        XCTAssertEqual(rig.tab.session.undoLabel, "Add form field")
        XCTAssertNil(rig.viewer.overlay(0).item("forms.ghost"))
    }

    func test_aClickDrawsAFieldOfTheDefaultSize() throws {
        let rig = try designing()
        rig.model.newKind = .checkBox

        rig.tap(ViewPoint(100, 300))

        let widget = try XCTUnwrap(rig.form.find("Check1")?.widgets[0])
        XCTAssertEqual(widget.rect.width, 14, accuracy: 0.01)
        XCTAssertEqual(widget.rect.height, 14, accuracy: 0.01)
        XCTAssertEqual(widget.rect.left, 100, accuracy: 0.01)
    }

    func test_aRadioButtonDrawnWithAGroupSelectedJoinsIt() throws {
        let rig = try designing()
        rig.model.select("plan", 0)
        rig.model.newKind = .radio

        rig.tap(ViewPoint(300, 300))

        XCTAssertEqual(rig.form.find("plan")?.widgets.count, 3)
        XCTAssertEqual(rig.model.groupName, "plan")
    }

    func test_aDragOnAFieldMovesIt() throws {
        let rig = try designing()
        let before = try XCTUnwrap(rig.form.find("code")?.widgets[0].rect)
        let start = rig.centre("code")

        rig.drag(from: start, to: ViewPoint(start.x + 50, start.y - 30))

        let after = try XCTUnwrap(rig.form.find("code")?.widgets[0].rect)
        XCTAssertEqual(after.left, before.left + 50, accuracy: 0.01)
        XCTAssertEqual(after.bottom, before.bottom + 30, accuracy: 0.01)
        XCTAssertEqual(after.width, before.width, accuracy: 0.01)
        XCTAssertEqual(rig.model.selected, "code")
        XCTAssertEqual(rig.tab.session.undoLabel, "Move form field")
    }

    func test_aDragFromAHandleResizesTheSelectedField() throws {
        let rig = try designing()
        rig.tap(rig.centre("name"))
        let before = try XCTUnwrap(rig.form.find("name")?.widgets[0].rect)

        rig.drag(from: ViewPoint(before.right, 792 - before.bottom), to: ViewPoint(before.right + 20, 792 - before.bottom + 10))

        let after = try XCTUnwrap(rig.form.find("name")?.widgets[0].rect)
        XCTAssertEqual(after.left, before.left, accuracy: 0.01)
        XCTAssertEqual(after.top, before.top, accuracy: 0.01)
        XCTAssertEqual(after.right, before.right + 20, accuracy: 0.01)
        XCTAssertEqual(after.bottom, before.bottom - 10, accuracy: 0.01)
    }

    func test_aPressOnNothingClearsTheSelectionAndAClickOnAFieldSelectsIt() throws {
        let rig = try designing()

        rig.tap(rig.centre("agree"))
        XCTAssertEqual(rig.model.selected, "agree")
        XCTAssertEqual(rig.model.cardKind, .checkBox)
        rig.tap(ViewPoint(400, 40))

        XCTAssertNil(rig.model.selected)
        XCTAssertNil(rig.model.cardKind)
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_aFingerBetweenCloseFieldsScrollsWhileEditingToo() throws {
        let rig = try designing()
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        let agree = rig.centre("agree")

        XCTAssertFalse(tool.takes(rig.pointer(ViewPoint(100, 792 - 635), pressed: true)))
        XCTAssertTrue(tool.takes(rig.pointer(rig.centre("name"), pressed: true)))
        XCTAssertTrue(tool.takes(rig.pointer(ViewPoint(agree.x + 20, agree.y), pressed: true)))
    }

    func test_aFingerIsTheToolsOnlyOverAFieldUnlessAKindIsChosenToDraw() throws {
        let rig = try designing()
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        XCTAssertTrue(tool.takes(rig.pointer(rig.centre("name"), pressed: true)))
        XCTAssertFalse(tool.takes(rig.pointer(ViewPoint(400, 40), pressed: true)))
        rig.model.newKind = .text
        XCTAssertTrue(tool.takes(rig.pointer(ViewPoint(400, 40), pressed: true)))
    }

    func test_theHandlesOfTheSelectedFieldAreTheToolsToo() throws {
        let rig = try designing()
        rig.tap(rig.centre("name"))
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        let box = try XCTUnwrap(rig.form.find("name")?.widgets[0].rect)

        XCTAssertTrue(tool.takes(rig.pointer(ViewPoint(box.right + 6, 792 - box.bottom + 6), pressed: true)))
    }

    func test_aMoveThatEndsOffThePageStaysOnIt() throws {
        let rig = try designing()
        let start = rig.centre("name")

        rig.drag(from: start, to: ViewPoint(5000, start.y))

        let after = try XCTUnwrap(rig.form.find("name")?.widgets[0].rect)
        XCTAssertLessThanOrEqual(after.right, 612.01)
    }

    func test_cancellingADragLeavesNothingBehind() throws {
        let rig = try designing()
        rig.model.newKind = .text
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        tool.press(rig.pointer(ViewPoint(100, 300), pressed: true))
        tool.move(rig.pointer(ViewPoint(200, 340), pressed: true))
        XCTAssertNotNil(rig.viewer.overlay(0).item("forms.ghost"))
        tool.cancel()

        XCTAssertNil(rig.viewer.overlay(0).item("forms.ghost"))
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_foundFieldsAreOutlinedDashedUntilTheyAreAdded() async throws {
        let bytes = try PdfFromText.create("Name: ______________________\nCity: ______________________", fonts: FormPdfs.fonts).bytes
        let rig = try FormsRig(bytes)
        rig.model.setDesigning(true)

        await rig.model.findFields()

        let dashed = frames(rig).filter { $0.style.dash == [4, 3] }
        XCTAssertEqual(dashed.count, rig.model.found.count)
        XCTAssertFalse(dashed.isEmpty)
        rig.model.addFound()
        XCTAssertTrue(frames(rig).filter { $0.style.dash == [4, 3] }.isEmpty)
    }

    func test_framesFollowThePagesInView() async throws {
        let rig = try designing()
        try rig.change("Add form field") { try FormEdits.add($0, .checkBox, 1, PdfRect(20, 20, 34, 34), nil) }
        await waitUntil { rig.model.rows.count == 7 }
        XCTAssertTrue(frames(rig, page: 1).isEmpty)

        rig.viewer.pageIndex = 1
        await waitUntil { !self.frames(rig, page: 1).isEmpty }

        XCTAssertTrue(frames(rig).isEmpty)
    }

    func test_leavingThePanelTakesTheFramesOffTheGlass() throws {
        let rig = try designing()
        rig.model.select("name", 0)

        rig.viewer.endToolMarks(prefix: "forms.")
        rig.model.detach()

        XCTAssertTrue(rig.viewer.overlay(0).items.isEmpty)
    }
}
