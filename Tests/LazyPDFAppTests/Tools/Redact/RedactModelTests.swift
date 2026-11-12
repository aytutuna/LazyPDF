import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Redact panel as the window drives it. Windows has no test of the panel itself; its pieces are tested with MarkListTests
// and RedactJobTests. These cover what the panel adds: the marks kept per document, their count reaching the unsaved-changes
// question, the boxes on the pages, the review list, and the summary that waits for the copy's tab.

@MainActor
final class RedactModelTests: XCTestCase {
    private static let line = "Write to ann@example.com today."

    private func attached(_ bytes: [UInt8]? = nil, password: String? = nil) throws -> (model: RedactModel, rig: SecurityRig) {
        let rig = try SecurityRig(bytes ?? Pdfs.text(2, Self.line), password: password)
        let model = RedactModel(fonts: FakeFonts(), images: FakeCodec())
        rig.attach(model)
        return (model, rig)
    }

    private func drag(_ viewer: PanelViewer, page: Int = 0, from: ViewPoint, to: ViewPoint, fromKeys: Bool = false) throws {
        let tool = try XCTUnwrap(viewer.pointerTool)
        func pointer(_ at: ViewPoint, _ pressed: Bool, keys: Bool = false) -> PagePointer {
            PagePointer(page: page, point: at, view: at, pressed: pressed, clicks: pressed ? 0 : 1, fromKeys: keys)
        }
        tool.press(pointer(from, true))
        tool.move(pointer(to, true))
        tool.release(pointer(to, false, keys: fromKeys))
    }

    func test_aSearchMarksEveryMatchAndTheCountReachesTheTab() async throws {
        let (model, rig) = try attached()
        model.query = "example"

        await model.markWords()

        XCTAssertEqual(model.marks.count, 2)
        XCTAssertEqual(rig.tab.pendingMarks, 2)
        XCTAssertEqual(rig.host.statuses.last, "2 marks added.")
        XCTAssertTrue(model.action!.canRun())
        XCTAssertNotNil(rig.viewer.overlay(0).item("redact.mark.0"))
        XCTAssertNotNil(rig.viewer.overlay(1).item("redact.mark.0"))
    }

    func test_marksComeBackWhenThePanelIsShownAgainAndStayWithTheirOwnDocument() async throws {
        let (model, rig) = try attached()
        model.query = "example"
        await model.markWords()

        model.detach()
        XCTAssertTrue(model.marks.isEmpty)
        XCTAssertEqual(rig.tab.pendingMarks, 2)
        let other = try SecurityRig(Pdfs.text(1, Self.line))
        other.attach(model)
        XCTAssertTrue(model.marks.isEmpty)
        XCTAssertEqual(other.tab.pendingMarks, 0)
        model.detach()
        model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertEqual(model.marks.count, 2)
    }

    func test_aSecondSearchAddsOnlyWhatIsNew() async throws {
        let (model, rig) = try attached()
        model.query = "example"
        await model.markWords()

        await model.markWords()

        XCTAssertEqual(model.marks.count, 2)
        XCTAssertEqual(rig.host.statuses.last, "Nothing new to mark.")
    }

    func test_aKindOfDataIsMarkedAndAnEmptyAnswerIsSaid() async throws {
        let (model, rig) = try attached()

        model.kindIndex = 0
        await model.markKind()
        XCTAssertEqual(model.marks.map(\.label), ["ann@example.com", "ann@example.com"])

        model.clearMarks()
        model.kindIndex = 4
        await model.markKind()
        XCTAssertEqual(rig.host.statuses.last, "Nothing found.")
    }

    func test_pagesWithNoTextAreReportedBecauseNothingWasSearchedThere() async throws {
        let (model, rig) = try attached(PdfFromText.create("ann@example.com\u{0C}\u{0C}more", fonts: FakeFonts()).bytes)
        model.kindIndex = 0

        await model.markKind()

        XCTAssertEqual(rig.host.notices.first?.title, "1 page has no text")
    }

    func test_timedOutPagesDoNotHideThePagesWithNoText() {
        let hit = MarkItem(RedactionMark.fromRect(0, PdfRect(10, 10, 50, 20)), "x")

        let both = RedactModel.notice(RedactFound(items: [hit], pictures: 2, timedOut: [3]))
        let onlySlow = RedactModel.notice(RedactFound(items: [hit], pictures: 0, timedOut: [3]))

        XCTAssertEqual(both?.title, "2 pages have no text")
        XCTAssertTrue(both?.text.hasSuffix(TimedOutText.forPages([3])!) == true)
        XCTAssertEqual(onlySlow?.title, "Some pages were not searched")
        XCTAssertNil(RedactModel.notice(RedactFound(items: [], pictures: 0, timedOut: [3])))
    }

    func test_aBoxDrawnOnThePageIsMarkedAndShownThere()async throws {
        let (model, rig) = try attached()

        model.setDrawing(true)
        XCTAssertTrue(model.drawing)
        try drag(rig.viewer, from: ViewPoint(50, 60), to: ViewPoint(150, 90))

        XCTAssertEqual(model.marks.map(\.label), ["Box"])
        XCTAssertEqual(rig.tab.pendingMarks, 1)
        XCTAssertNil(rig.viewer.overlay(0).item("redact.preview"))
        XCTAssertNotNil(rig.viewer.overlay(0).item("redact.mark.0"))
        let bounds = model.marks[0].mark.quads[0].bounds
        XCTAssertEqual([bounds.left, bounds.right], [50.0, 150.0])
        XCTAssertEqual([bounds.bottom, bounds.top], [702.0, 732.0])
    }

    func test_aDragThatIsTooSmallMarksNothingAndAKeyboardClickGetsABoxOfTheUsualSize() async throws {
        let (model, rig) = try attached()
        model.setDrawing(true)

        try drag(rig.viewer, from: ViewPoint(50, 60), to: ViewPoint(52, 61))
        XCTAssertTrue(model.marks.isEmpty)

        try drag(rig.viewer, from: ViewPoint(50, 60), to: ViewPoint(50, 60), fromKeys: true)
        let bounds = try XCTUnwrap(model.marks.first).mark.quads[0].bounds
        XCTAssertEqual(bounds.right - bounds.left, 160)
        XCTAssertEqual(bounds.top - bounds.bottom, 24)
    }

    func test_aDragPastThePageEdgeIsKeptOnThePage() async throws {
        let (model, rig) = try attached()
        model.setDrawing(true)

        try drag(rig.viewer, from: ViewPoint(500, 700), to: ViewPoint(900, 1000))

        let bounds = try XCTUnwrap(model.marks.first).mark.quads[0].bounds
        XCTAssertEqual([bounds.right, bounds.bottom], [612, 0])
    }

    func test_theToolLetsGoWhenTheViewerTakesThePointerBack() async throws {
        let (model, rig) = try attached()
        model.setDrawing(true)

        rig.viewer.pointerTool = nil

        XCTAssertFalse(model.drawing)
        model.setDrawing(true)
        model.setDrawing(false)
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_aMarkCanBeJumpedToAndTakenOutAndAllCanBePutBack() async throws {
        let (model, rig) = try attached()
        model.query = "example"
        await model.markWords()
        let second = model.marks[1]

        model.jump(second)
        XCTAssertEqual(rig.viewer.sent.last, 1)
        XCTAssertEqual(rig.viewer.revealed.last?.page, 1)
        XCTAssertEqual(model.selected, second.id)
        model.removeSelected()
        XCTAssertEqual(model.marks.count, 1)
        XCTAssertNil(rig.viewer.overlay(1).item("redact.mark.0"))
        XCTAssertEqual(rig.host.notices.last?.title, "Mark removed")
        let one = try XCTUnwrap(rig.host.lastNoticeAction)
        XCTAssertEqual(one.text, "Put it back")
        one.run()
        XCTAssertEqual(model.marks.count, 2)
        model.remove(model.marks[1])

        model.clearMarks()
        XCTAssertTrue(model.marks.isEmpty)
        XCTAssertEqual(rig.tab.pendingMarks, 0)
        let notice = try XCTUnwrap(rig.host.notices.last)
        XCTAssertEqual(notice.title, "1 mark removed")
        let back = try XCTUnwrap(rig.host.lastNoticeAction)
        XCTAssertEqual(back.text, "Put them back")
        back.run()
        XCTAssertEqual(model.marks.count, 1)
    }

    func test_aMarkIsNotPutBackOnceThePagesHaveChanged() async throws {
        let (model, rig) = try attached()
        model.query = "example"
        await model.markWords()

        model.remove(model.marks[0])
        let back = try XCTUnwrap(rig.host.lastNoticeAction)
        try PageOperations.delete(rig.tab.document, [1])
        try rig.tab.commit("Delete")
        back.run()

        XCTAssertEqual(rig.host.notices.last?.title, "Marks removed")
        XCTAssertEqual(model.marks.count, 1)
        await waitUntil { model.marks.isEmpty }
    }

    func test_marksAreDroppedWhenThePagesMoveUnderThem() async throws {
        let (model, rig) = try attached()
        model.query = "example"
        await model.markWords()

        try PageOperations.reorder(rig.tab.document, [1, 0])
        try rig.tab.commit("Move")
        await waitUntil { model.marks.isEmpty }

        XCTAssertEqual(rig.tab.pendingMarks, 0)
        XCTAssertEqual(rig.host.notices.last?.title, "Marks removed")
        XCTAssertNil(rig.viewer.overlay(0).item("redact.mark.0"))
    }

    func test_aFileThatForbidsChangesCannotBeRedacted() async throws {
        let (model, _) = try attached(try Pdfs.restricted(.print), password: "")

        XCTAssertTrue(model.restricted)
        XCTAssertFalse(model.action!.canRun())
    }

    func test_aMenuMarkOnAFileThatForbidsChangesAddsNothing() async throws {
        let rig = try SecurityRig(try Pdfs.restricted(.print), password: "")
        rig.viewer.runs = [SelectedRun(page: 0, range: TextRange(0, 4), text: "Hello", quads: [TextQuad(100, 700, 180, 700, 180, 712, 100, 712)])]
        let model = RedactModel(fonts: FakeFonts(), images: FakeCodec())
        rig.host.pendingMark = .redact

        rig.attach(model)
        await Task.yield()
        await Task.yield()
        await model.markSelection()

        XCTAssertTrue(model.restricted)
        XCTAssertEqual(model.marks.count, 0)
        XCTAssertEqual(rig.tab.pendingMarks, 0)
    }

    func test_aRunOpensTheCopyWithoutThePasswordAndTheMarksAreDoneWith() async throws {
        let (model, rig) = try attached()
        await model.markKind()

        await model.action!.run()

        let made = try XCTUnwrap(rig.host.openedNew.first)
        XCTAssertEqual(made.title, "a (redacted).pdf")
        XCTAssertNil(made.password)
        XCTAssertFalse(try TextCache(PdfDocument.open(made.pdf)).get(0).text.contains("example"))
        XCTAssertTrue(model.marks.isEmpty)
        XCTAssertEqual(rig.tab.pendingMarks, 0)
        XCTAssertEqual(rig.host.statuses.last, "Redacted copy opened.")
        XCTAssertFalse(rig.tab.isDirty)
    }

    func test_theSummaryWaitsForTheTabOfTheCopyAndShowsThereOnly() async throws {
        let (model, rig) = try attached()
        await model.markKind()
        await model.action!.run()
        let made = try XCTUnwrap(rig.host.openedNew.first)
        model.detach()

        let elsewhere = try SecurityRig(Pdfs.text(1), title: "b.pdf")
        elsewhere.attach(model)
        XCTAssertNil(model.result)
        model.detach()
        let copy = try SecurityRig(made.pdf, title: made.title)
        copy.attach(model)

        let summary = try XCTUnwrap(model.result)
        XCTAssertTrue(summary.clean)
        XCTAssertEqual(summary.title, "Check passed")
        model.detach()
        copy.attach(model)
        XCTAssertNotNil(model.result)
    }

    func test_aRunOnAProtectedFileSaysTheCopyHasNoPassword() async throws {
        let plain = try PdfDocument.open(Pdfs.text(1, Self.line))
        let security = PdfSecurity.create(userPassword: "open", ownerPassword: "owner", permissions: .all, strength: .aes256,
                                          firstId: [UInt8](repeating: 3, count: 16))
        let bytes = try plain.saveRewrite(PdfSaveOptions(security: security))
        let (model, rig) = try attached(bytes, password: "open")
        await model.markKind()

        await model.action!.run()

        XCTAssertEqual(rig.host.openedNew.count, 1)
        XCTAssertFalse(try PdfDocument.open(rig.host.openedNew[0].pdf).isEncrypted)
        XCTAssertEqual(rig.host.notices.last?.title, "The copy has no password")
    }

    func test_aCancelledRunKeepsTheMarks() async throws {
        let (model, rig) = try attached()
        await model.markKind()
        rig.host.token.cancel()

        await model.action!.run()

        XCTAssertTrue(rig.host.openedNew.isEmpty)
        XCTAssertEqual(model.marks.count, 2)
        XCTAssertEqual(rig.tab.pendingMarks, 2)
    }

    func test_theMenuMarkIsTakenAsTheToolAttaches() async throws {
        let rig = try SecurityRig(Pdfs.text(1, Self.line))
        rig.viewer.runs = [SelectedRun(page: 0, range: TextRange(0, 4), text: "Hello", quads: [TextQuad(100, 700, 180, 700, 180, 712, 100, 712)])]
        let model = RedactModel(fonts: FakeFonts(), images: FakeCodec())
        rig.host.pendingMark = .redact

        rig.attach(model)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.marks.count, 1)
    }
}
