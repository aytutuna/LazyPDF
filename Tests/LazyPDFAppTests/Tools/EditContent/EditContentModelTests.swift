import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Windows has no test of EditContentPanel itself, since the panel needs a window; the model is driven here the way the page view
// drives it: through the pointer tool the viewer holds, the field the page view puts over a line, and the panel's own calls.

@MainActor
final class EditContentModelTests: XCTestCase {
    private let hello = EditPdf.make("BT /F1 12 Tf 50 700 Td (Hello from the tests.) Tj ET")

    private func start(_ bytes: [UInt8]? = nil, password: String? = nil) throws -> (model: EditContentModel, rig: ContentRig) {
        let rig = try ContentRig(bytes ?? hello, password: password)
        let model = EditContentModel()
        rig.attach(model)
        return (model, rig)
    }

    private func pageText(_ tab: DocumentTab) throws -> String {
        try PageEditor(tab.session, 0).text.text
    }

    private func lineCenter(_ rig: ContentRig) throws -> ViewPoint {
        let block = try XCTUnwrap(try PageEditor(rig.tab.session, 0).objects.first as? TextObject)
        let d = rig.viewer.geometry(0).toDisplay(try XCTUnwrap(block.lines.first).bounds)
        return ViewPoint(d.x + d.width / 2, d.y + d.height / 2)
    }

    private func pointer(_ at: ViewPoint, pressed: Bool = true, touch: Bool = false) -> PagePointer {
        PagePointer(page: 0, point: at, view: at, pressed: pressed, clicks: 1, touch: touch)
    }

    private func click(_ rig: ContentRig, _ at: ViewPoint) throws {
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        tool.press(pointer(at))
        tool.release(pointer(at))
    }

    private func drag(_ rig: ContentRig, from: ViewPoint, to: ViewPoint) throws {
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        tool.press(pointer(from))
        tool.move(pointer(to))
        tool.release(pointer(to))
    }

    private func field(_ rig: ContentRig) throws -> OverlayField {
        try XCTUnwrap(rig.viewer.overlay(0).fields.first)
    }

    // Added behind the model's back, as another tool would; picking the mode again makes it read the page.
    private func addPicture(_ rig: ContentRig, _ model: EditContentModel) throws -> Int {
        let outcome = try ContentEdits(rig.tab, fonts: FakeFonts(), codec: FakeCodec()).addImage(0, PdfRect(100, 400, 200, 500), [1])
        XCTAssertTrue(outcome.done)
        model.selectMode(.select)
        return try XCTUnwrap(try PageEditor(rig.tab.session, 0).objects.last { $0 is ImageObject }).id
    }

    private func lockedBy(_ bytes: [UInt8], permissions: PdfPermissions) throws -> [UInt8] {
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: permissions, strength: .aes256,
                                          firstId: [UInt8](repeating: 7, count: 16))
        return try PdfDocument.open(bytes).saveRewrite(PdfSaveOptions(security: security))
    }

    private func signed(_ bytes: [UInt8]) throws -> [UInt8] {
        let document = try PdfDocument.open(bytes)
        let perms = PdfDictionary()
        perms["UR3"] = try document.add(PdfDictionary())
        document.catalog["Perms"] = perms
        return try document.saveRewrite(PdfSaveOptions())
    }

    func test_clickingALineOpensTheEditorOverItWithItsText() async throws {
        let (model, rig) = try start()

        try click(rig, try lineCenter(rig))

        let open = try field(rig)
        XCTAssertEqual(open.text, "Hello from the tests.")
        if case .at = open.caret {} else { XCTFail("The caret should go where the click was.") }
        XCTAssertEqual(model.action?.text, "Apply text")
        XCTAssertTrue(rig.host.problems.isEmpty)
    }

    func test_returnKeepsTheTypedLine() async throws {
        let (model, rig) = try start()
        try click(rig, try lineCenter(rig))

        try field(rig).commit("Goodbye from the tests.")

        XCTAssertTrue(try pageText(rig.tab).contains("Goodbye from the tests."))
        XCTAssertEqual(rig.host.status, "Text changed.")
        XCTAssertNil(model.action)
        XCTAssertTrue(rig.viewer.overlay(0).fields.isEmpty)
        XCTAssertTrue(try rig.tab.undo())
        XCTAssertTrue(try pageText(rig.tab).contains("Hello from the tests."))
    }

    func test_escapeDropsWhatWasTyped() async throws {
        let (model, rig) = try start()
        try click(rig, try lineCenter(rig))

        let open = try field(rig)
        open.typed("Something else")
        open.drop()

        XCTAssertTrue(try pageText(rig.tab).contains("Hello from the tests."))
        XCTAssertEqual(rig.tab.revision, 0)
        XCTAssertNil(model.action)
    }

    func test_aLineTheEngineRefusesComesBackWithTheReason() async throws {
        let (model, rig) = try start()
        try click(rig, try lineCenter(rig))

        try field(rig).commit("漢字")

        XCTAssertEqual(model.message?.caution, true)
        XCTAssertEqual(try field(rig).text, "漢字")
        XCTAssertEqual(rig.tab.revision, 0)
        XCTAssertEqual(model.action?.text, "Apply text")
    }

    func test_aPressElsewhereOnThePageKeepsWhatWasTyped() async throws {
        let (model, rig) = try start()
        try click(rig, try lineCenter(rig))
        try field(rig).typed("Typed in place.")

        try click(rig, ViewPoint(400, 600))

        XCTAssertTrue(try pageText(rig.tab).contains("Typed in place."))
        model.detach()
    }

    func test_thePinnedButtonKeepsTheTypedText() async throws {
        let (model, rig) = try start()
        try click(rig, try lineCenter(rig))
        try field(rig).typed("Applied by the button.")

        XCTAssertEqual(model.action?.canRun(), true)
        await model.action?.run()

        XCTAssertTrue(try pageText(rig.tab).contains("Applied by the button."))
        XCTAssertNil(model.action)
    }

    func test_handInKeepsWhatIsStillBeingTyped() async throws {
        let (model, rig) = try start()
        try click(rig, try lineCenter(rig))
        try field(rig).typed("Handed in.")

        XCTAssertTrue(model.handIn())

        XCTAssertTrue(try pageText(rig.tab).contains("Handed in."))
    }

    func test_aFileThatForbidsChangesIsLeftAlone() async throws {
        let (model, rig) = try start(try lockedBy(hello, permissions: .print), password: "")

        try click(rig, try lineCenter(rig))

        XCTAssertEqual(rig.host.problems.first?.title, "This file cannot be changed")
        XCTAssertTrue(rig.viewer.overlay(0).fields.isEmpty)
        model.detach()
    }

    func test_aSignedFileAsksOnceBeforeTheFirstEdit() async throws {
        let (model, rig) = try start(try signed(hello))
        let center = try lineCenter(rig)

        try click(rig, center)
        XCTAssertEqual(rig.host.notices.map(\.title), ["Check before going on"])
        XCTAssertTrue(rig.viewer.overlay(0).fields.isEmpty)

        rig.host.notices[0].action?.run()
        XCTAssertEqual(rig.viewer.overlay(0).fields.count, 1)
        try field(rig).commit("Signed and changed.")
        try click(rig, center)
        XCTAssertEqual(rig.host.notices.count, 1)
        model.detach()
    }

    func test_deleteRemovesTheSelectionAndEscapeLetsGoOfIt() async throws {
        let (model, rig) = try start()
        let id = try addPicture(rig, model)
        model.selectObject(try XCTUnwrap(model.objectRows.first { $0.id == id }))
        XCTAssertTrue(model.hasSelection)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        XCTAssertTrue(tool.key(.escape, modifiers: []))
        XCTAssertFalse(model.hasSelection)
        XCTAssertFalse(tool.key(.escape, modifiers: []))

        model.selectObject(try XCTUnwrap(model.objectRows.first { $0.id == id }))
        XCTAssertTrue(tool.key(.delete, modifiers: []))
        XCTAssertTrue(try PageEditor(rig.tab.session, 0).objects.filter { $0 is ImageObject }.isEmpty)
        XCTAssertEqual(rig.host.status, "Deleted.")
        XCTAssertFalse(model.hasSelection)
    }

    func test_escapeLeavesTheTextBoxMode() async throws {
        let (model, rig) = try start()
        model.selectMode(.textBox)
        XCTAssertEqual(model.mode, .textBox)

        XCTAssertTrue(try XCTUnwrap(rig.viewer.pointerTool).key(.escape, modifiers: []))

        XCTAssertEqual(model.mode, .select)
    }

    func test_draggingASelectedPictureMovesIt() async throws {
        let (model, rig) = try start()
        let id = try addPicture(rig, model)
        let before = try XCTUnwrap(try PageEditor(rig.tab.session, 0).objects[id] as? ImageObject).bounds
        model.selectObject(try XCTUnwrap(model.objectRows.first { $0.id == id }))
        let d = rig.viewer.geometry(0).toDisplay(before)
        let center = ViewPoint(d.x + d.width / 2, d.y + d.height / 2)

        try drag(rig, from: center, to: ViewPoint(center.x + 40, center.y))

        let after = try XCTUnwrap(try PageEditor(rig.tab.session, 0).objects.last { $0 is ImageObject }).bounds
        XCTAssertEqual(after.left, before.left + 40, accuracy: 1)
        XCTAssertEqual(rig.host.status, "Moved.")
        XCTAssertTrue(model.hasSelection)
    }

    func test_theSurfaceTakesAFingerOnlyOverWhatItCanDo() async throws {
        let (model, rig) = try start()
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        XCTAssertFalse(tool.takes(pointer(ViewPoint(500, 700), touch: true)))
        XCTAssertFalse(tool.takes(pointer(try lineCenter(rig), touch: true)))
        let id = try addPicture(rig, model)
        let bounds = try XCTUnwrap(try PageEditor(rig.tab.session, 0).objects.first { $0.id == id }).bounds
        let d = rig.viewer.geometry(0).toDisplay(bounds)
        XCTAssertTrue(tool.takes(pointer(ViewPoint(d.x + d.width / 2, d.y + d.height / 2), touch: true)))
        model.detach()
    }

    private func routed() throws -> (model: EditContentModel, tab: DocumentTab, viewer: ViewerModel) {
        let tab = DocumentTab(session: try PdfEditSession.open(hello), renderer: FakeRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(tab)
        let model = EditContentModel()
        model.attach(tab, viewer, ContentHost())
        return (model, tab, viewer)
    }

    private func onScreen(_ viewer: ViewerModel, _ point: ViewPoint) throws -> ViewPoint {
        try XCTUnwrap(viewer.pageToView(0)).transform(point)
    }

    func test_aMouseClickOnALineThroughTheViewerOpensTheEditor() async throws {
        let (model, tab, viewer) = try routed()
        let block = try XCTUnwrap(try PageEditor(tab.session, 0).objects.first as? TextObject)
        let d = viewer.geometry(0).toDisplay(try XCTUnwrap(block.lines.first).bounds)
        let at = try onScreen(viewer, ViewPoint(d.x + d.width / 2, d.y + d.height / 2))

        viewer.pointerDown(at)
        viewer.pointerUp(at)

        XCTAssertEqual(viewer.overlay(0).fields.first?.text, "Hello from the tests.")
        model.detach()
    }

    func test_aMouseBandThroughTheViewerSelectsSeveralObjects() async throws {
        let (model, tab, viewer) = try routed()
        let outcome = try ContentEdits(tab, fonts: FakeFonts(), codec: FakeCodec()).addImage(0, PdfRect(100, 400, 200, 500), [1])
        XCTAssertTrue(outcome.done)
        model.selectMode(.select)

        let from = try onScreen(viewer, ViewPoint(5, 5))
        let to = try onScreen(viewer, ViewPoint(600, 780))
        viewer.pointerDown(from)
        viewer.pointerMove(to)
        viewer.pointerUp(to)

        XCTAssertEqual(model.selectedObjects().count, 2)
        model.detach()
    }

    func test_theListAddsAndTakesFromTheSelectionWhenSeveralAreWanted() async throws {
        let (model, rig) = try start()
        _ = try addPicture(rig, model)
        let rows = model.objectRows
        XCTAssertEqual(rows.count, 2)

        model.selectSeveral = true
        model.selectObject(rows[0])
        model.selectObject(rows[1])
        XCTAssertEqual(model.selectedRowIds, Set(rows.map(\.id)))
        model.selectObject(rows[0])
        XCTAssertEqual(model.selectedRowIds, [rows[1].id])
        model.selectSeveral = false
        model.selectObject(rows[0])

        XCTAssertEqual(model.selectedRowIds, [rows[0].id])
        model.detach()
    }

    func test_aLineOfTheSelectedBlockIsOpenedFromTheList() async throws {
        let (model, rig) = try start()
        model.selectObject(try XCTUnwrap(model.objectRows.first))

        let row = try XCTUnwrap(model.lineRows.first)
        model.editLine(row)

        XCTAssertEqual(row.title, "Hello from the tests.")
        XCTAssertEqual(try field(rig).text, "Hello from the tests.")
        model.detach()
    }

    func test_aFingersHintDoesNotPromiseADrag() async throws {
        let (model, _) = try start()
        let mouse = model.hint

        model.useTouch()
        XCTAssertNotEqual(model.hint, mouse)
        XCTAssertFalse(model.hint.contains("Drag to select"))
        model.selectMode(.textBox)

        XCTAssertTrue(model.hint.hasSuffix("Two fingers scroll the page."))
        model.detach()
    }

    func test_aLinkIsMadeByDraggingAnAreaAndTypingWhereItGoes() async throws {
        let (model, rig) = try start()
        model.selectMode(.link)
        XCTAssertNil(model.action)

        try drag(rig, from: ViewPoint(100, 300), to: ViewPoint(220, 340))
        XCTAssertNotNil(model.linkArea)
        XCTAssertTrue(model.sections.link)
        XCTAssertEqual(model.action?.canRun(), false)

        model.linkText = "example.com"
        XCTAssertEqual(model.action?.text, "Add link")
        XCTAssertEqual(model.action?.canRun(), true)
        await model.action?.run()

        let links = PdfLinks.read(rig.tab.document, rig.tab.document.pages[0])
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.uri, "https://example.com")
        XCTAssertEqual(rig.host.status, "Link added.")
        XCTAssertNil(model.linkArea)
    }

    func test_clickingALinkLoadsItAndItCanBeRemoved() async throws {
        let (model, rig) = try start()
        _ = try ContentEdits(rig.tab, fonts: FakeFonts(), codec: FakeCodec()).setLink(0, PdfRect(100, 600, 200, 640), UriAction("https://old.example"), nil)
        model.selectMode(.link)
        XCTAssertEqual(model.linkRows.map(\.title), ["Link to https://old.example"])

        try click(rig, ViewPoint(150, 172))

        XCTAssertEqual(model.linkText, "https://old.example")
        XCTAssertEqual(model.action?.text, "Save link")
        XCTAssertTrue(model.sections.removeLink)

        model.removeLink()

        XCTAssertTrue(PdfLinks.read(rig.tab.document, rig.tab.document.pages[0]).isEmpty)
        XCTAssertEqual(rig.host.status, "Link removed.")
    }

    func test_aLinkAreaOnAPageThatWentIsLetGoOf() async throws {
        let rig = try ContentRig(Pdfs.text(2))
        let model = EditContentModel()
        rig.attach(model)
        model.selectMode(.link)
        model.startLink(1, PdfRect(100, 600, 200, 640), nil)
        XCTAssertNotNil(model.linkArea)

        try PageOperations.delete(rig.tab.document, [1])
        try rig.tab.commit("Delete page")
        await waitUntil { model.linkArea == nil }

        model.linkText = "example.com"
        model.applyLink()
        XCTAssertEqual(rig.tab.pageCount, 1)
        XCTAssertNil(model.action)
        model.detach()
    }

    func test_aLinkEditOnAPageThatWentIsRefused() async throws {
        let rig = try ContentRig(Pdfs.text(1))
        let edits = ContentEdits(rig.tab, fonts: FakeFonts(), codec: FakeCodec())
        let link = PdfLink(PdfRect(0, 0, 10, 10), nil, UriAction("https://a.example"), nil)

        let added = try edits.setLink(3, PdfRect(100, 600, 200, 640), UriAction("https://example.com"), nil)
        let removed = try edits.removeLink(3, link)

        XCTAssertFalse(added.done)
        XCTAssertFalse(removed.done)
        XCTAssertTrue(edits.links(3).isEmpty)
        XCTAssertEqual(rig.tab.revision, 0)
    }

    func test_replaceAllChangesTheWordsAndSaysHowMany() async throws {
        let (model, rig) = try start()
        model.findText = "Hello"
        model.replaceText = "Goodbye"

        await model.replaceAll()

        XCTAssertTrue(try pageText(rig.tab).contains("Goodbye from the tests."))
        XCTAssertEqual(rig.host.statuses.last, "Text replaced.")
        XCTAssertEqual(model.message?.text, "Replaced 1 time.")
        XCTAssertFalse(model.isReplacing)
        XCTAssertEqual(rig.tab.session.undoLabel, "Replace text")
    }

    func test_aCancelledTokenStopsReplaceAllBeforeItStarts() async throws {
        let rig = try ContentRig(hello)
        let edits = ContentEdits(rig.tab, fonts: FakeFonts(), codec: FakeCodec())
        let token = CancelToken()
        token.cancel()

        do {
            _ = try await edits.replaceAll(rig.tab.session.current, "Hello", "Goodbye", TextSearchOptions(), token)
            XCTFail("A cancelled job should not give a copy.")
        } catch is CancellationError {}

        XCTAssertEqual(rig.tab.revision, 0)
    }

    func test_aReplaceAllThatEndsOnAnotherDocumentLeavesTheNewOnesRevisionAlone() async throws {
        let (model, rig) = try start()
        let other = try ContentRig(hello)
        rig.host.before = { model.attach(other.tab, other.viewer, other.host) }
        model.findText = "Hello"
        model.replaceText = "Goodbye"

        await model.replaceAll()
        try click(other, try lineCenter(other))
        try field(other).typed("Not yet in the file.")
        try Pdfs.retitle(other.tab.session, "Changed elsewhere")
        try other.tab.commit("Properties")
        await waitUntil { !other.host.problems.isEmpty }

        XCTAssertEqual(other.host.problems.first?.title, "Typed text was not kept")
        model.detach()
    }

    func test_aCancelledReplaceAllChangesNothing() async throws {
        let (model, rig) = try start()
        rig.host.cancelled = true
        model.findText = "Hello"

        await model.replaceAll()

        XCTAssertEqual(rig.host.status, "Canceled.")
        XCTAssertEqual(rig.tab.revision, 0)
        XCTAssertFalse(model.isReplacing)
    }

    func test_replaceAllOnAFileThatForbidsChangesIsRefused() async throws {
        let (model, rig) = try start(try lockedBy(hello, permissions: .print), password: "")
        model.findText = "Hello"

        await model.replaceAll()

        XCTAssertEqual(rig.host.problems.first?.title, "This file cannot be changed")
        XCTAssertEqual(rig.tab.revision, 0)
    }

    func test_aChangeFromElsewhereDropsAnOpenEditorAndSaysSo() async throws {
        let (model, rig) = try start()
        try click(rig, try lineCenter(rig))
        try field(rig).typed("Not yet in the file.")

        try Pdfs.retitle(rig.tab.session, "Changed elsewhere")
        try rig.tab.commit("Properties")
        await waitUntil { !rig.host.problems.isEmpty }

        XCTAssertEqual(rig.host.problems.first?.title, "Typed text was not kept")
        XCTAssertTrue(rig.viewer.overlay(0).fields.isEmpty)
        XCTAssertNil(model.action)
    }

    func test_theViewersOwnToolTakingThePointerEndsTheModeUntilOnePickedAgain() async throws {
        let (model, rig) = try start()
        XCTAssertTrue(model.isActive)

        rig.viewer.pointerTool = nil
        await waitUntil { !model.isActive }
        XCTAssertEqual(model.hint, "Pick a mode above to edit the page again.")

        model.selectMode(.select)
        XCTAssertTrue(model.isActive)
        XCTAssertNotNil(rig.viewer.pointerTool)
    }

    func test_detachLeavesNothingOnThePages() async throws {
        let (model, rig) = try start()
        let id = try addPicture(rig, model)
        model.selectObject(try XCTUnwrap(model.objectRows.first { $0.id == id }))
        XCTAssertFalse(rig.viewer.overlay(0).items.isEmpty)
        try click(rig, try lineCenter(rig))
        try field(rig).typed("Kept on the way out.")

        model.detach()

        XCTAssertTrue(rig.viewer.overlay(0).items.isEmpty)
        XCTAssertTrue(rig.viewer.overlay(0).fields.isEmpty)
        XCTAssertNil(rig.viewer.pointerTool)
        XCTAssertTrue(try pageText(rig.tab).contains("Kept on the way out."))
    }

    func test_theListNamesWhatThePageHoldsAndPicksIt() async throws {
        let (model, rig) = try start()
        _ = try addPicture(rig, model)

        XCTAssertEqual(model.objectRows.map(\.title), ["Text: Hello from the tests.", "Picture 1"])

        model.selectObject(model.objectRows[1])

        XCTAssertTrue(model.sections.image)
        XCTAssertEqual(rig.viewer.revealed.count, 1)
    }

    func test_aSizeThatIsNotANumberGoesBackToTheOneInTheFile() async throws {
        let (model, rig) = try start()
        model.selectObject(try XCTUnwrap(model.objectRows.first))

        model.sizeText = "huge"
        model.commitSize()

        XCTAssertEqual(model.sizeText, "12")
        XCTAssertEqual(rig.tab.revision, 0)
    }

    func test_aNewSizeRestylesTheSelectedBlock() async throws {
        let (model, rig) = try start()
        model.selectObject(try XCTUnwrap(model.objectRows.first))

        model.sizeText = "20"
        model.commitSize()

        XCTAssertEqual(try XCTUnwrap(try PageEditor(rig.tab.session, 0).objects[0] as? TextObject).size, 20, accuracy: 0.5)
        XCTAssertEqual(rig.host.status, "Size changed.")
    }

    func test_aSizeTypedWithoutReturnIsKeptWhenTheTextIsHandedIn() async throws {
        let (model, rig) = try start()
        model.selectObject(try XCTUnwrap(model.objectRows.first))

        model.sizeText = "20"
        XCTAssertTrue(model.handIn())

        XCTAssertEqual(try XCTUnwrap(try PageEditor(rig.tab.session, 0).objects[0] as? TextObject).size, 20, accuracy: 0.5)
        XCTAssertEqual(rig.host.status, "Size changed.")
    }

    func test_aNewTextBoxIsDraggedOutAndTyped() async throws {
        let (model, rig) = try start()
        model.selectMode(.textBox)

        try drag(rig, from: ViewPoint(100, 300), to: ViewPoint(300, 360))
        XCTAssertEqual(try field(rig).text, "")
        try field(rig).commit("A new box of text")

        XCTAssertTrue(try pageText(rig.tab).contains("A new box of text"))
        XCTAssertEqual(rig.host.status, "Text box added.")
    }

    func test_aNewBoxThatLosesTheFocusToTheSizeFieldKeepsItsTextAndTakesTheNewSize() async throws {
        let (model, rig) = try start()
        model.selectMode(.textBox)
        try drag(rig, from: ViewPoint(100, 300), to: ViewPoint(300, 360))
        let open = try field(rig)
        open.typed("A new box of text")

        open.commit("A new box of text", focusLost: true)

        XCTAssertTrue(rig.viewer.overlay(0).fields.isEmpty)
        XCTAssertEqual(model.action?.canRun(), true)
        XCTAssertFalse(try pageText(rig.tab).contains("A new box of text"))
        model.sizeText = "18"
        model.commitSize()

        let again = try field(rig)
        XCTAssertEqual(again.text, "A new box of text")
        XCTAssertEqual(again.look.size, 18)
        again.commit("A new box of text")
        XCTAssertTrue(try pageText(rig.tab).contains("A new box of text"))
    }

    func test_aNewBoxThatLosesTheFocusWhileEmptyIsNotDropped() async throws {
        let (model, rig) = try start()
        model.selectMode(.textBox)
        try drag(rig, from: ViewPoint(100, 300), to: ViewPoint(300, 360))

        try field(rig).commit("", focusLost: true)
        model.setBold(true)

        XCTAssertEqual(try field(rig).text, "")
        XCTAssertTrue(try field(rig).look.bold)
        model.detach()
    }

    func test_aLineTheEngineRefusesAfterTheFocusWentStaysClosedUntilTheLookChanges() async throws {
        let (model, rig) = try start()
        try click(rig, try lineCenter(rig))

        try field(rig).commit("漢字", focusLost: true)

        XCTAssertTrue(rig.viewer.overlay(0).fields.isEmpty)
        XCTAssertEqual(model.message?.caution, true)
        XCTAssertEqual(model.action?.canRun(), true)
        model.setBold(true)
        XCTAssertEqual(try field(rig).text, "漢字")
        model.detach()
    }

    func test_aPictureIsAddedFromTheFilePickerAndSelected() async throws {
        let (model, rig) = try start()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("p.png")
        try Data([1, 2, 3]).write(to: file)
        rig.host.picked = [ToolFile(url: file)]

        await model.addPicture()

        XCTAssertEqual(rig.host.status, "Picture added.")
        XCTAssertTrue(model.sections.image)
        XCTAssertTrue(model.hasSelection)
    }
}
