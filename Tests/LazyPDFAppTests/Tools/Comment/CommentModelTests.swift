import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// The Comment tool as the window drives it. Windows has no test of CommentPanel; the cases are those its code handles: the
// pointer tools it hands the viewer, the text typed into a field on the page, what a file may not take, the look of the mark
// picked, and the long changes (import, flatten, attach) that hold the document.

/// A window that records what it was told and gives the tool the files a test chooses.
@MainActor
final class MarkHost: ToolHost {
    final class Files: ToolFilePicker, ToolFileExporter {
        var picked: [ToolFile] = []
        var exported: [(name: String, data: Data)] = []
        var gaveUp = false

        func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] { picked }
        func pickFolder() async -> ToolFile? { nil }

        func export(_ files: [URL]) async -> [URL] {
            if gaveUp { return [] }
            for file in files { exported.append((file.lastPathComponent, (try? Data(contentsOf: file)) ?? Data())) }
            return files
        }
    }

    var problems: [Problem] = []
    var notices: [(title: String, text: String, action: NoticeAction?)] = []
    var statuses: [String] = []
    var busyTexts: [String] = []
    var runningInside: [Bool] = []
    var cancelOnStart = false
    let files = Files()

    var filePicker: ToolFilePicker { files }
    var fileExporter: ToolFileExporter { files }

    func runBusy(_ text: String, _ work: @MainActor (CancelToken) async throws -> Void) async throws {
        busyTexts.append(text)
        runningInside.append(MarkWork.shared.running)
        let token = CancelToken()
        if cancelOnStart { token.cancel() }
        do {
            try await work(token)
        } catch is CancellationError {
            statuses.append("Cancelled.")
        }
    }

    func setBusyText(_ text: String) {}
    func showProblem(_ problem: Problem) { problems.append(problem) }
    func showNotice(_ title: String, _ text: String, _ action: NoticeAction?) { notices.append((title, text, action)) }
    func setStatus(_ sentence: String) { statuses.append(sentence) }
    func open(_ url: URL, access: FileAccess?) async {}
    func openNew(_ pdf: [UInt8], title: String, password: String?, certificate: CertificateChoice?) async {}
    func tryReload(_ tab: DocumentTab) async -> Bool { true }
}

@MainActor
final class CommentModelTests: XCTestCase {
    private struct Rig {
        let model: CommentModel
        let tab: DocumentTab
        let viewer: PanelViewer
        let host: MarkHost
        let f: CommentFixture
    }

    private func attached(_ bytes: [UInt8]? = nil, password: String? = nil, marks: Bool = false, pages: Int = 1,
                          touch: Bool = false) throws -> Rig {
        let f = try CommentFixture(pages: pages)
        let tab: DocumentTab
        if let bytes {
            tab = DocumentTab(session: try PdfEditSession.open(bytes, password: password), renderer: FakeRenderer(), url: nil,
                              title: "a.pdf", password: password)
        } else {
            tab = f.tab
        }
        if marks {
            let marker = Marker(tab.document, FakeFonts(), author: "Ana", date: DateTimeOffset(2026, 11, 4, 10, 0, 0))
            try marker.add(.rectangle, 0, [markPt(60, 80), markPt(260, 140)], MarkStyle(color: [0.9, 0.15, 0.15], width: 3))
            try tab.commit("Marks")
        }
        let viewer = PanelViewer(tab)
        let host = MarkHost()
        let model = CommentModel(fonts: FakeFonts(), touch: touch)
        model.author = "Ana"
        model.attach(tab, viewer, host)
        return Rig(model: model, tab: tab, viewer: viewer, host: host, f: f)
    }

    private func click(_ rig: Rig, _ at: ViewPoint, dragTo end: ViewPoint? = nil, page: Int = 0) {
        let tool = rig.viewer.pointerTool!
        tool.press(PagePointer(page: page, point: at, view: at, pressed: true, clicks: 1))
        if let end { tool.move(PagePointer(page: page, point: end, view: end, pressed: true, clicks: 0)) }
        let last = end ?? at
        tool.release(PagePointer(page: page, point: last, view: last, pressed: false, clicks: 0))
    }

    private func marks(_ rig: Rig) -> [PdfAnnotation] {
        PdfAnnotations.read(rig.tab.document, rig.tab.document.pages[0])
    }

    func test_pickingAToolGivesThePageThePointerTool() throws {
        let rig = try attached()
        XCTAssertNil(rig.viewer.pointerTool)
        XCTAssertEqual(rig.viewer.mode, .select)

        rig.model.pick(.rectangle)
        XCTAssertTrue(rig.viewer.pointerTool is DrawTool)
        XCTAssertEqual(rig.model.hint, "Drag to draw a rectangle.")

        rig.model.pick(.edit)
        XCTAssertTrue(rig.viewer.pointerTool is EditTool)

        rig.viewer.mode = .hand
        rig.model.pick(.selectText)
        XCTAssertEqual(rig.viewer.mode, .select)
    }

    func test_aToolThatIsPlacedByClickSaysTheKeyboardWorksToo() throws {
        let rig = try attached()

        rig.model.pick(.note)

        XCTAssertEqual(rig.model.hint, "Click where the note goes. Or press Enter on the page.")
    }

    func test_detachingGivesThePointerBackAndKeepsTheLook() throws {
        let rig = try attached()
        rig.model.pick(.rectangle)
        rig.model.setWidth(5)

        rig.model.detach()

        XCTAssertNil(rig.viewer.pointerTool)
        rig.model.attach(rig.tab, rig.viewer, rig.host)
        XCTAssertEqual(rig.model.width, 5)
        XCTAssertEqual(rig.model.tool, .rectangle)
        XCTAssertTrue(rig.viewer.pointerTool is DrawTool)
    }

    func test_aRectangleIsDrawnWithTheLookAndIsOneUndoStep() throws {
        let rig = try attached()
        rig.model.pick(.rectangle)
        rig.model.setColor([0.2, 0.7, 0.3])
        rig.model.setWidth(4)

        click(rig, markPt(60, 80), dragTo: markPt(260, 140))

        let made = try XCTUnwrap(marks(rig).first)
        XCTAssertEqual(marks(rig).count, 1)
        XCTAssertEqual(made.type, .square)
        XCTAssertEqual(made.color, [0.2, 0.7, 0.3])
        XCTAssertEqual(made.border.width, 4)
        XCTAssertEqual(made.title, "Ana")
        XCTAssertEqual(rig.tab.session.undoLabel, "Rectangle")
        XCTAssertTrue(try rig.tab.undo())
        XCTAssertTrue(marks(rig).isEmpty)
    }

    func test_aNoteTakesTheTextTypedIntoAFieldOnThePage() throws {
        let rig = try attached()
        rig.model.pick(.note)

        click(rig, markPt(100, 100))
        let field = try XCTUnwrap(rig.viewer.overlay(0).fields.first)
        XCTAssertTrue(marks(rig).isEmpty)
        field.commit("Check the total")

        let made = try XCTUnwrap(marks(rig).first)
        XCTAssertEqual(made.type, .text)
        XCTAssertEqual(made.contents, "Check the total")
        XCTAssertTrue(rig.viewer.overlay(0).fields.isEmpty)
    }

    func test_aNoteWithNoTextOrDroppedIsNotMade() throws {
        let rig = try attached()
        rig.model.pick(.note)

        click(rig, markPt(100, 100))
        rig.viewer.overlay(0).fields[0].commit("   ")
        click(rig, markPt(100, 100))
        rig.viewer.overlay(0).fields[0].drop()

        XCTAssertTrue(marks(rig).isEmpty)
        XCTAssertTrue(rig.host.problems.isEmpty)
    }

    func test_handingInKeepsTheTextBeingTyped() throws {
        let rig = try attached()
        rig.model.pick(.textBox)
        click(rig, markPt(60, 80), dragTo: markPt(260, 140))
        rig.viewer.overlay(0).fields[0].text = "Hello"

        XCTAssertTrue(rig.model.handIn())

        let made = try XCTUnwrap(marks(rig).first)
        XCTAssertEqual(made.type, .freeText)
        XCTAssertEqual(made.contents, "Hello")
    }

    func test_textTheFontsCannotDrawIsToldAndTheFieldOpensAgainWithIt() async throws {
        let rig = try attached()
        rig.model.pick(.textBox)
        click(rig, markPt(60, 80), dragTo: markPt(260, 140))

        rig.viewer.overlay(0).fields[0].commit("Çalışma ğ")

        XCTAssertEqual(rig.host.problems.map(\.title), ["Text not drawn"])
        XCTAssertTrue(marks(rig).isEmpty)
        await waitUntil { rig.viewer.overlay(0).fields.count == 1 }
        XCTAssertEqual(rig.viewer.overlay(0).fields[0].text, "Çalışma ğ")
    }

    func test_aMarkWithNoAreaIsExplained() throws {
        let rig = try attached()
        rig.model.pick(.rectangle)

        click(rig, markPt(60, 80), dragTo: markPt(260, 80))

        XCTAssertTrue(marks(rig).isEmpty)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Nothing to draw"])
    }

    func test_aPolygonIsEndedByTheFinishButtonForAFinger() throws {
        let rig = try attached()
        rig.model.pick(.polygon)
        for corner in [markPt(10, 10), markPt(100, 10)] { click(rig, corner) }
        XCTAssertFalse(rig.model.canFinishShape)

        click(rig, markPt(100, 100))
        XCTAssertTrue(rig.model.canFinishShape)
        rig.model.finishShape()

        XCTAssertEqual(marks(rig).first?.type, .polygon)
        XCTAssertFalse(rig.model.canFinishShape)
    }

    func test_aPolygonOnAPageThatUndoRemovedIsDroppedAndFinishingDoesNotCrash() async throws {
        let rig = try attached(pages: 3)
        rig.model.pick(.polygon)
        for corner in [markPt(10, 10), markPt(100, 10), markPt(100, 100)] { click(rig, corner, page: 2) }
        XCTAssertTrue(rig.model.canFinishShape)

        try PageOperations.delete(rig.tab.document, [2])
        try rig.tab.commit("Delete pages")
        await waitUntil { !rig.model.shapeStarted }

        XCTAssertFalse(rig.model.canFinishShape)
        rig.model.finishShape()
        XCTAssertTrue(rig.host.problems.isEmpty)
    }

    func test_aPolygonThatSlippedPastTheWatchIsStillNotWrittenOnAMissingPage() throws {
        let rig = try attached(pages: 3)

        rig.model.drew(.polygon, 2, [markPt(10, 10), markPt(100, 10), markPt(100, 100)])
        XCTAssertEqual(PdfAnnotations.read(rig.tab.document, rig.tab.document.pages[2]).count, 1)
        try PageOperations.delete(rig.tab.document, [2])
        rig.model.drew(.polygon, 2, [markPt(10, 10), markPt(100, 10), markPt(100, 100)])

        XCTAssertTrue(rig.host.problems.isEmpty)
    }

    func test_aShapeUnderWayCanBeCancelledFromThePanel() throws {
        let rig = try attached()
        rig.model.pick(.cloud)
        XCTAssertFalse(rig.model.shapeStarted)

        click(rig, markPt(10, 10))
        XCTAssertTrue(rig.model.shapeStarted)
        XCTAssertFalse(rig.model.canFinishShape)
        rig.model.cancelShape()

        XCTAssertFalse(rig.model.shapeStarted)
        XCTAssertTrue(rig.viewer.overlay(0).items.isEmpty)
    }

    func test_switchingToolDropsTheShapeUnderWay() throws {
        let rig = try attached()
        rig.model.pick(.polygon)
        click(rig, markPt(10, 10))
        click(rig, markPt(100, 10))

        rig.model.pick(.rectangle)

        XCTAssertFalse(rig.model.shapeStarted)
        XCTAssertTrue(rig.viewer.overlay(0).items.isEmpty)
    }

    func test_aPhoneTellsPolygonsAreEndedWithTheFinishButtonAndLeavesTheKeyboardOut() throws {
        let rig = try attached(touch: true)

        rig.model.pick(.polygon)
        XCTAssertEqual(rig.model.hint, "Tap each corner, then tap Finish shape.")
        rig.model.pick(.note)
        XCTAssertEqual(rig.model.hint, "Click where the note goes.")
    }

    func test_theMovedMarksToolListsTheMarksOfThePageInView() throws {
        let rig = try attached(marks: true)
        rig.model.pick(.rectangle)
        XCTAssertTrue(rig.model.marks.isEmpty)

        rig.model.pick(.edit)
        let row = try XCTUnwrap(rig.model.marks.first)
        XCTAssertEqual(rig.model.marks.count, 1)
        XCTAssertTrue(row.spoken.hasPrefix("Rectangle"))
        XCTAssertTrue(row.spoken.hasSuffix("Page 1"))
        XCTAssertFalse(row.isSelected)

        rig.model.select(row)

        XCTAssertEqual(rig.model.selected?.title, "Selected: Rectangle")
        XCTAssertTrue(try XCTUnwrap(rig.model.marks.first).isSelected)
    }

    func test_aStampTakesTheStandardNameOrWhatWasTyped() throws {
        let rig = try attached()
        rig.model.pick(.stamp)

        rig.model.setStampName("DRAFT")
        click(rig, markPt(200, 300))
        rig.model.setStampName("Paid in full")
        click(rig, markPt(200, 400))

        let names = marks(rig).map { ($0.dictionary["Name"] as? PdfName)?.value }
        XCTAssertEqual(names, ["Draft", "Paid in full"])
    }

    func test_aStampFieldEmptiedByTypingStaysEmptyAndStampsTheFirstLabel() throws {
        let rig = try attached()
        rig.model.pick(.stamp)

        rig.model.setStampName("")
        XCTAssertEqual(rig.model.stampName, "")
        click(rig, markPt(200, 300))

        let names = marks(rig).map { ($0.dictionary["Name"] as? PdfName)?.value }
        XCTAssertEqual(names, [AnnotationText.standardStamps[0]])
    }

    func test_theEraserTakesTheDrawingsItCrosses() throws {
        let rig = try attached(marks: true)
        rig.model.pick(.eraser)

        click(rig, markPt(150, 60), dragTo: markPt(150, 100))

        XCTAssertTrue(marks(rig).isEmpty)
        XCTAssertEqual(rig.tab.session.undoLabel, "Erase")
    }

    func test_aFileThatDoesNotAllowCommentsTakesNone() throws {
        let rig = try attached(try Pdfs.restricted(.print), password: "")

        rig.model.pick(.rectangle)

        XCTAssertFalse(rig.model.allowed)
        XCTAssertFalse(rig.model.canChange)
        XCTAssertEqual(rig.model.tool, .selectText)
        XCTAssertEqual(rig.model.hint, "This file does not allow comments.")
        XCTAssertTrue(rig.model.canExport)
    }

    func test_aSignedFileIsSaidToBeSignedWhenThePanelIsShown() throws {
        let rig = try attached(try Pdfs.signed(certified: false))

        XCTAssertEqual(rig.host.notices.map(\.title), ["File is signed"])
        XCTAssertEqual(rig.host.notices.first?.text, "This file is signed, so changing it breaks the signatures.")
        XCTAssertTrue(rig.model.allowed)
    }

    func test_aMarkPickedShowsItsLookAndTheSliderSettlesIntoTheFileAsOneStep() throws {
        let rig = try attached(marks: true)
        rig.model.pick(.edit)

        rig.model.editTool?.select(marks(rig)[0])

        XCTAssertEqual(rig.model.selected?.title, "Selected: Rectangle")
        XCTAssertEqual(rig.model.width, 3)
        XCTAssertTrue(rig.model.isChosen(CommentModel.colours[3].rgb))
        let before = rig.tab.revision

        rig.model.setWidth(6)
        rig.model.setWidth(7)
        XCTAssertEqual(rig.tab.revision, before)
        rig.model.settle()

        XCTAssertEqual(rig.tab.revision, before + 1)
        XCTAssertEqual(marks(rig)[0].border.width, 7)
        XCTAssertEqual(rig.tab.session.undoLabel, "Change look")
    }

    func test_aMarkIsDeletedAndTheSelectionGoesWithIt() async throws {
        let rig = try attached(marks: true)
        rig.model.pick(.edit)
        rig.model.editTool?.select(marks(rig)[0])

        rig.model.deleteSelected()

        XCTAssertTrue(marks(rig).isEmpty)
        await waitUntil { rig.model.selected == nil }
        XCTAssertEqual(rig.tab.session.undoLabel, "Delete")
    }

    func test_theViewersOwnHandButtonTakesThePointerBack() async throws {
        let rig = try attached()
        rig.model.pick(.rectangle)

        rig.viewer.pointerTool = nil

        await waitUntil { rig.model.tool == .selectText }
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_markingWithNothingSelectedSaysSo() async throws {
        let rig = try attached()

        await rig.model.markup(.highlight)

        XCTAssertEqual(rig.host.statuses, ["Select some text first."])
        XCTAssertTrue(marks(rig).isEmpty)
    }

    // Flattening

    func test_flatteningBurnsTheMarksInWhileTheDocumentIsHeld() async throws {
        let rig = try attached(marks: true)
        await waitUntil { rig.model.flattenable == 1 }
        XCTAssertTrue(try XCTUnwrap(rig.model.action).canRun())

        await rig.model.action?.run()

        XCTAssertEqual(rig.host.runningInside, [true])
        XCTAssertFalse(MarkWork.shared.running)
        XCTAssertTrue(marks(rig).isEmpty)
        XCTAssertEqual(rig.host.statuses, ["Flattened 1 mark."])
        XCTAssertEqual(rig.tab.session.undoLabel, "Flatten comments")
        await waitUntil { rig.model.flattenable == 0 }
        XCTAssertFalse(try XCTUnwrap(rig.model.action).canRun())
    }

    func test_cancellingTheFlattenPutsTheFileBack() async throws {
        let rig = try attached(marks: true)
        rig.host.cancelOnStart = true
        let before = rig.tab.revision

        await rig.model.action?.run()

        XCTAssertEqual(marks(rig).count, 1)
        XCTAssertEqual(rig.tab.revision, before)
        XCTAssertEqual(rig.host.statuses, ["Cancelled."])
        XCTAssertFalse(MarkWork.shared.running)
        XCTAssertEqual(rig.tab.session.undoLabel, "Marks")
    }

    func test_aSignedFileAsksBeforeFlattening() async throws {
        let first = DocumentTab(session: try PdfEditSession.open(try Pdfs.signed(certified: false, pages: 1)), renderer: FakeRenderer(),
                                url: nil, title: "a.pdf")
        let marker = Marker(first.document, FakeFonts(), author: "Ana", date: DateTimeOffset(2026, 11, 4, 10, 0, 0))
        try marker.add(.rectangle, 0, [markPt(60, 80), markPt(260, 140)], markRed)
        try first.commit("Marks")
        let rig = try attached(first.session.current)
        rig.host.notices.removeAll()
        await waitUntil { rig.model.flattenable == 1 }

        await rig.model.action?.run()

        XCTAssertEqual(rig.host.notices.map(\.title), ["Check before going on"])
        XCTAssertEqual(marks(rig).count, 1)

        rig.host.notices[0].action?.run()
        await waitUntil { rig.model.flattenable == 0 && !MarkWork.shared.running }
        XCTAssertTrue(marks(rig).isEmpty)
    }

    func test_aFileWithNothingToFlattenHasNoWorkForTheButton() throws {
        let rig = try attached()

        XCTAssertFalse(try XCTUnwrap(rig.model.action).canRun())
    }

    // Exchange

    private func exported(_ xfdf: Bool) async throws -> (rig: Rig, name: String, data: Data) {
        let rig = try attached(marks: true)
        await rig.model.exportComments(xfdf: xfdf)
        let sent = try XCTUnwrap(rig.host.files.exported.first)
        return (rig, sent.name, sent.data)
    }

    func test_exportingHandsAnFdfOrAnXfdfFileToTheExporter() async throws {
        let fdf = try await exported(false)
        XCTAssertEqual(fdf.name, "a.fdf")
        XCTAssertFalse(fdf.data.isEmpty)
        XCTAssertEqual(fdf.rig.host.statuses, ["Comments exported."])
        XCTAssertEqual(fdf.rig.host.busyTexts, ["Exporting comments"])

        let xfdf = try await exported(true)
        XCTAssertEqual(xfdf.name, "a.xfdf")
        XCTAssertTrue(String(decoding: xfdf.data, as: UTF8.self).contains("xfdf"))
    }

    func test_exportingAFileWithNoCommentsSaysSo() async throws {
        let rig = try attached()

        await rig.model.exportComments(xfdf: false)

        XCTAssertEqual(rig.host.statuses, ["No comments to export."])
        XCTAssertTrue(rig.host.files.exported.isEmpty)
    }

    func test_anXfdfExportSaysWhatItHadNoRoomFor() async throws {
        let rig = try attached(marks: true)
        let marker = Marker(rig.tab.document, FakeFonts(), author: "Ana", date: DateTimeOffset(2026, 11, 4, 10, 0, 0))
        _ = try marker.addAttachment(0, markPt(300, 100), "data.csv", [1, 2, 3])
        try rig.tab.commit("Attach file")

        await rig.model.exportComments(xfdf: true)

        XCTAssertEqual(rig.host.notices.map(\.title), ["Some content left out"])
        XCTAssertEqual(rig.host.notices.first?.text, "1 attachment or picture stamp is not in an XFDF file. Export as FDF to keep it.")
    }

    func test_givingUpTheSavePanelSavesNothingAndSaysNothing() async throws {
        let rig = try attached(marks: true)
        rig.host.files.gaveUp = true

        await rig.model.exportComments(xfdf: false)

        XCTAssertTrue(rig.host.statuses.isEmpty)
    }

    func test_importingAddsTheCommentsOfThePickedFileAsOneStep() async throws {
        let source = try await exported(false)
        let target = try attached()
        let dir = TempDir(self)
        target.host.files.picked = [ToolFile(url: dir.file("notes.fdf", [UInt8](source.data)))]

        await target.model.importComments()

        XCTAssertEqual(marks(target).count, 1)
        XCTAssertEqual(target.host.statuses, ["Imported 1 comment."])
        XCTAssertEqual(target.host.runningInside, [true])
        XCTAssertEqual(target.tab.session.undoLabel, "Import comments")
        XCTAssertFalse(MarkWork.shared.running)

        await target.model.importComments()

        XCTAssertEqual(marks(target).count, 1)
        XCTAssertEqual(target.host.notices.last?.title, "Nothing imported")
        XCTAssertEqual(target.host.notices.last?.text, "The comments in notes.fdf are already in this file or belong to other pages.")
    }

    func test_aFileThatIsNotACommentFileIsExplained() async throws {
        let rig = try attached()
        let dir = TempDir(self)
        rig.host.files.picked = [ToolFile(url: dir.file("notes.xfdf", [1, 2, 3, 4]))]

        await rig.model.importComments()

        XCTAssertEqual(rig.host.problems.map(\.title), ["Not a comment file"])
        XCTAssertEqual(rig.host.problems.first?.text, "notes.xfdf could not be read. Pick an FDF or XFDF file.")
        XCTAssertFalse(MarkWork.shared.running)
        XCTAssertFalse(rig.tab.isDirty)
    }

    func test_importingIntoAFileThatTakesNoCommentsDoesNothing() async throws {
        let rig = try attached(try Pdfs.restricted(.print), password: "")

        await rig.model.importComments()

        XCTAssertTrue(rig.host.busyTexts.isEmpty)
    }

    // Attaching

    func test_attachingPutsThePickedFileOnThePage() async throws {
        let rig = try attached()
        let dir = TempDir(self)
        rig.host.files.picked = [ToolFile(url: dir.file("data.csv", [1, 2, 3]))]
        rig.model.pick(.attach)

        click(rig, markPt(300, 100))
        await waitUntil { rig.tab.session.undoLabel == "Attach file" }

        let made = try XCTUnwrap(marks(rig).first)
        XCTAssertEqual(made.type, .fileAttachment)
        XCTAssertEqual(rig.host.busyTexts, ["Attaching file"])
        XCTAssertFalse(MarkWork.shared.running)
    }

    func test_aFileOverFiftyMegabytesIsRefused() async throws {
        let rig = try attached()
        let dir = TempDir(self)
        let big = dir.file("big.bin", [0])
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 51 * 1024 * 1024)
        try handle.close()
        rig.host.files.picked = [ToolFile(url: big)]
        rig.model.pick(.attach)

        click(rig, markPt(300, 100))
        await waitUntil { !rig.host.problems.isEmpty }

        XCTAssertEqual(rig.host.problems.first?.text, "big.bin is over 50 MB. Attach a smaller file.")
        XCTAssertTrue(marks(rig).isEmpty)
    }
}
