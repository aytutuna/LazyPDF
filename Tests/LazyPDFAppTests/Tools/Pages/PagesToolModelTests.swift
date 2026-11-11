import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Pages panel as the window drives it. Windows has no test of the panel itself (its jobs are in PageEditsTests and the
// organize view's in OrganizeViewTests), so these follow its code: the bar over the grid, the sections and the pinned button.

@MainActor
final class PagesToolModelTests: XCTestCase {
    private func attached(_ pages: Int = 5, bytes: [UInt8]? = nil) throws -> (model: PagesToolModel, rig: PagesRig) {
        let rig = try PagesRig(bytes ?? Pdfs.text(pages))
        let model = PagesToolModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        return (model, rig)
    }

    private func press(_ tool: CropTool, _ x: Double, _ y: Double, page: Int = 0) {
        tool.press(PagePointer(page: page, point: ViewPoint(x, y), view: .zero, pressed: true, clicks: 1))
    }

    private func release(_ tool: CropTool, _ x: Double, _ y: Double, page: Int = 0, fromKeys: Bool = false) {
        tool.release(PagePointer(page: page, point: ViewPoint(x, y), view: .zero, pressed: false, clicks: 0, fromKeys: fromKeys))
    }

    private func draw(_ model: PagesToolModel, from: (Double, Double) = (50, 60), to: (Double, Double) = (150, 160)) throws {
        let tool = try XCTUnwrap(model.crop)
        press(tool, from.0, from.1)
        release(tool, to.0, to.1)
    }

    func test_theBarChangesTheChosenPagesAsOneStepAndKeepsThemChosen() throws {
        let (model, rig) = try attached()
        model.grid.select([1, 2])

        model.turn(90)

        XCTAssertEqual(rig.tab.document.pages[1].rotate, 90)
        XCTAssertEqual(rig.tab.document.pages[2].rotate, 90)
        XCTAssertEqual(model.grid.selection, [1, 2])
        XCTAssertEqual(model.grid.summary, "2 of 5 selected")
        XCTAssertEqual(rig.host.statuses.last, "2 pages rotated")
    }

    func test_earlierAndLaterMoveTheChosenPagesOneStep() throws {
        let (model, rig) = try attached()
        let was = rig.tab.order
        model.grid.select([2])
        XCTAssertTrue(model.canMoveEarlier)
        XCTAssertTrue(model.canMoveLater)

        model.earlier()
        XCTAssertEqual(rig.tab.order, [was[0], was[2], was[1], was[3], was[4]])
        XCTAssertEqual(model.grid.selection, [1])

        model.later()
        model.later()
        XCTAssertEqual(rig.tab.order, [was[0], was[1], was[3], was[2], was[4]])
        XCTAssertEqual(model.grid.selection, [3])
    }

    func test_pagesApartEachMoveOneStepAsOneUndo() throws {
        let (model, rig) = try attached(6)
        let was = rig.tab.order
        model.grid.select([2, 5])

        model.earlier()

        XCTAssertEqual(rig.tab.order, [was[0], was[2], was[1], was[3], was[5], was[4]])
        XCTAssertEqual(model.grid.selection, [1, 4])
        XCTAssertEqual(rig.host.statuses.last, "2 pages moved")
        try rig.tab.undo()
        XCTAssertEqual(rig.tab.order, was)
    }

    func test_thePagesAtTheEdgesCannotMovePastIt() throws {
        let (model, _) = try attached()

        model.grid.select([0])
        XCTAssertFalse(model.canMoveEarlier)
        model.grid.select([4])
        XCTAssertFalse(model.canMoveLater)
        model.grid.selectNone()
        XCTAssertFalse(model.canEdit)
    }

    func test_deletingEveryPageIsRefusedAndAPartIsNot() throws {
        let (model, rig) = try attached(3)

        model.grid.selectAll()
        model.remove()
        XCTAssertEqual(rig.tab.pageCount, 3)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Cannot delete every page"])

        model.grid.select([1])
        model.remove()
        XCTAssertEqual(rig.tab.pageCount, 2)
        XCTAssertTrue(model.grid.selected.isEmpty)
    }

    func test_choosingOnePageShowsItAndChoosingTwoDoesNot() throws {
        let (model, rig) = try attached()

        model.grid.toggle(3)
        XCTAssertEqual(rig.viewer.sent, [3])
        model.grid.toggle(2)
        XCTAssertEqual(rig.viewer.sent, [3])
    }

    func test_theSummaryCountsThePagesOrTheChoice() throws {
        let (model, _) = try attached()
        XCTAssertEqual(model.grid.summary, "5 pages")

        model.grid.select([1])

        XCTAssertEqual(model.grid.summary, "1 of 5 selected")
    }

    func test_aBlankPageGoesWhereTheChoiceSays() throws {
        let (model, rig) = try attached(3)
        model.grid.select([1])

        model.blank()

        XCTAssertEqual(rig.tab.pageCount, 4)
        XCTAssertEqual(model.grid.selection, [2])
    }

    func test_duplicatingKeepsTheTwoCopiesChosen() async throws {
        let (model, rig) = try attached(3)
        let was = rig.tab.order
        model.grid.select([1])

        await model.duplicate()

        XCTAssertEqual(rig.tab.text(1), was[1])
        XCTAssertEqual(rig.tab.text(2), was[1])
        XCTAssertEqual(model.grid.selection, [1, 2])
    }

    func test_extractingOpensANewFileAndLeavesTheDocument() async throws {
        let (model, rig) = try attached(4)
        model.grid.select([1, 2])

        await model.extract()

        XCTAssertEqual(rig.host.openedNew.map(\.title), ["a extract.pdf"])
        XCTAssertEqual(rig.tab.pageCount, 4)
        XCTAssertEqual(rig.host.statuses.last, "2 pages extracted")
    }

    func test_theCropSectionTakesThePointerAndDrawsABox() throws {
        let (model, rig) = try attached()
        XCTAssertNil(model.action)

        model.setExpanded(.crop, true)
        let tool = try XCTUnwrap(model.crop)

        XCTAssertTrue(rig.viewer.pointerTool === tool)
        XCTAssertTrue(model.cropDrawing)
        XCTAssertEqual(model.cropHint, "Drag a box on a page.")
        XCTAssertFalse(model.action!.canRun())

        try draw(model)

        XCTAssertEqual(model.cropBox, CropBox(page: 0, area: DisplayRect(50, 60, 100, 100)))
        XCTAssertTrue(model.action!.canRun())
        XCTAssertEqual(model.action?.text, "Crop pages")
        XCTAssertNotNil(rig.viewer.overlay(0).item("pages.crop"))
    }

    func test_aBoxOfNoSizeIsDropped() throws {
        let (model, rig) = try attached()
        model.setExpanded(.crop, true)

        try draw(model, from: (50, 60), to: (52, 61))

        XCTAssertNil(model.cropBox)
        XCTAssertNil(rig.viewer.overlay(0).item("pages.crop"))
    }

    func test_aBoxIsKeptOnThePageAndAKeyboardClickGetsOneOfTheUsualSize() throws {
        let (model, _) = try attached()
        model.setExpanded(.crop, true)
        let tool = try XCTUnwrap(model.crop)

        press(tool, 100, 700)
        release(tool, 100, 700, fromKeys: true)

        XCTAssertEqual(model.cropBox?.area, DisplayRect(100, 632, 240, 160))
    }

    func test_cropCoversTheChosenPagesElseEveryPageElseTheOneDrawnOn() async throws {
        let (model, rig) = try attached(3)
        model.setExpanded(.crop, true)

        try draw(model)
        await model.action!.run()
        XCTAssertEqual(PageGeometry(rig.tab.document.pages[0]).width, 100, accuracy: 0.1)
        XCTAssertNotEqual(PageGeometry(rig.tab.document.pages[1]).width, 100, accuracy: 0.1)
        XCTAssertNil(model.cropBox)

        model.grid.select([1, 2])
        try draw(model)
        await model.action!.run()
        XCTAssertEqual(PageGeometry(rig.tab.document.pages[1]).width, 100, accuracy: 0.1)
        XCTAssertEqual(PageGeometry(rig.tab.document.pages[2]).width, 100, accuracy: 0.1)
        XCTAssertEqual(model.grid.selection, [1, 2])

        model.grid.selectNone()
        model.cropAll = true
        try draw(model)
        XCTAssertTrue(model.cropHint.hasSuffix("Every page is changed."))
        await model.action!.run()
        XCTAssertTrue(rig.host.problems.isEmpty)
        XCTAssertEqual(rig.host.statuses.last, "3 pages cropped")
    }

    func test_removingTheCropCoversEveryPageWhenNoneIsChosen() async throws {
        let (model, rig) = try attached(2)
        model.setExpanded(.crop, true)
        try draw(model)
        await model.action!.run()
        XCTAssertEqual(PageGeometry(rig.tab.document.pages[0]).width, 100, accuracy: 0.1)

        model.removeCrop()

        XCTAssertNotEqual(PageGeometry(rig.tab.document.pages[0]).width, 100, accuracy: 0.1)
        XCTAssertEqual(rig.host.statuses.last, "Crop removed.")
    }

    func test_leavingTheCropSectionGivesThePointerBackAndForgetsTheBox() throws {
        let (model, rig) = try attached()
        model.setExpanded(.crop, true)
        try draw(model)

        model.setExpanded(.crop, false)

        XCTAssertNil(rig.viewer.pointerTool)
        XCTAssertNil(model.cropBox)
        XCTAssertNil(model.crop)
        XCTAssertEqual(model.section, .none)
        XCTAssertNil(model.action)
        XCTAssertNil(rig.viewer.overlay(0).item("pages.crop"))
    }

    func test_openingAnotherSectionClosesTheCropOne() throws {
        let (model, rig) = try attached()
        model.setExpanded(.crop, true)

        model.setExpanded(.resize, true)

        XCTAssertNil(rig.viewer.pointerTool)
        XCTAssertEqual(model.section, .resize)
        XCTAssertEqual(model.action?.text, "Resize pages")
    }

    func test_theViewersOtherPointersSwitchDrawingOffAndKeepTheBox() async throws {
        let (model, rig) = try attached()
        model.setExpanded(.crop, true)
        try draw(model)

        rig.viewer.pointerTool = nil
        await waitUntil { !model.cropDrawing }

        XCTAssertNotNil(model.cropBox)
        model.setDrawing(true)
        XCTAssertTrue(model.cropDrawing)
        XCTAssertTrue(rig.viewer.pointerTool === model.crop)
    }

    func test_theCropSectionComesBackWhenThePanelIsShownAgain() throws {
        let (model, rig) = try attached()
        model.setExpanded(.crop, true)

        model.detach()
        XCTAssertNil(rig.viewer.pointerTool)
        model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertTrue(rig.viewer.pointerTool === model.crop)
        XCTAssertNotNil(model.crop)
    }

    func test_aBoxOnAPageThatIsGoneIsForgotten() async throws {
        let (model, rig) = try attached(5)
        model.setExpanded(.crop, true)
        let tool = try XCTUnwrap(model.crop)
        press(tool, 50, 60, page: 4)
        release(tool, 150, 160, page: 4)
        XCTAssertEqual(model.cropBox?.page, 4)

        try PageOperations.delete(rig.tab.document, [4])
        try rig.tab.commit("Delete pages")
        await waitUntil { model.grid.cells.count == 4 }

        XCTAssertNil(model.cropBox)
    }

    func test_aCustomSizeNeedsNumbersAPageCanBe() async throws {
        let (model, rig) = try attached(2)
        model.setExpanded(.resize, true)
        model.paperIndex = PaperSize.all.count
        XCTAssertTrue(model.showsCustomSize)

        model.customWidth = "2"
        XCTAssertFalse(model.action!.canRun())
        model.customWidth = "wide"
        XCTAssertFalse(model.action!.canRun())
        model.customWidth = "200"
        model.customHeight = "300"
        XCTAssertTrue(model.action!.canRun())

        model.scaleContent = false
        await model.action!.run()

        let shown = PageGeometry(rig.tab.document.pages[0])
        XCTAssertEqual(shown.width, 200 * PageEdits.pointsPerMillimetre, accuracy: 0.1)
        XCTAssertEqual(shown.height, 300 * PageEdits.pointsPerMillimetre, accuracy: 0.1)
        XCTAssertEqual(rig.host.statuses.last, "2 pages resized")
    }

    func test_aPaperSizeResizesTheChosenPages() async throws {
        let (model, rig) = try attached(3)
        model.grid.select([1])
        model.setExpanded(.resize, true)
        model.paperIndex = 3

        XCTAssertTrue(model.resizeHint.hasSuffix("1 selected page is changed."))
        await model.action!.run()

        XCTAssertEqual(PageGeometry(rig.tab.document.pages[1]).width, 612, accuracy: 0.1)
        XCTAssertNotEqual(PageGeometry(rig.tab.document.pages[0]).width, 612, accuracy: 0.1)
    }

    func test_pagesAreNumberedFromTheFirstChosenToTheLast() async throws {
        let (model, rig) = try attached(5)
        model.grid.select([1, 2])
        model.setExpanded(.labels, true)
        XCTAssertEqual(model.labelHint, "Pages 2 to 3 are numbered.")

        model.labelStart = "0"
        XCTAssertFalse(model.action!.canRun())
        model.labelStart = "+5"
        XCTAssertFalse(model.action!.canRun())
        model.labelStart = "3"
        model.labelStyleIndex = 2
        model.labelPrefix = "A-"
        await model.action!.run()

        XCTAssertEqual(PdfPageLabels.labels(rig.tab.document), ["1", "A-III", "A-IV", "4", "5"])
        XCTAssertEqual(model.grid.selection, [1, 2])

        model.removeLabels()
        XCTAssertEqual(PdfPageLabels.labels(rig.tab.document), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(rig.host.statuses.last, "Labels removed.")
    }

    func test_withNothingChosenEveryPageIsNumbered() throws {
        let (model, _) = try attached()

        XCTAssertEqual(model.labelHint, "Every page is numbered.")
    }

    func test_pagesFromAFileGoWhereTheChoiceSaysWithTheRangeTyped() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        rig.pick(dir, "other.pdf", Pdfs.text(4, "Other"))
        model.grid.select([0])
        model.taken = "2-3"

        await model.fromFile()

        XCTAssertEqual(rig.tab.pageCount, 5)
        XCTAssertEqual(model.grid.selection, [1, 2])
        XCTAssertEqual(rig.host.statuses.last, "2 pages added")
    }

    func test_aRangePastTheEndOfTheFileIsReported() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        rig.pick(dir, "other.pdf", Pdfs.text(2, "Other"))
        model.taken = "9"

        await model.fromFile()

        XCTAssertEqual(rig.tab.pageCount, 3)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Pages not understood"])
    }

    func test_replacingPutsTheFilesPagesInPlaceOfTheChosen() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(5)
        let was = rig.tab.order
        rig.pick(dir, "other.pdf", Pdfs.text(3, "Other"))
        model.grid.select([1, 2])

        await model.replace()

        XCTAssertEqual(rig.tab.pageCount, 6)
        XCTAssertEqual(rig.tab.text(0), was[0])
        XCTAssertEqual(rig.tab.text(4), was[3])
        XCTAssertEqual(model.grid.selection, [1, 2, 3])
        XCTAssertEqual(rig.host.statuses.last, "Pages replaced.")
    }

    func test_aReplaceStaysWithTheFileItStartedOnWhenAnotherOpensMeanwhile() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(4)
        let other = try PagesRig(Pdfs.text(2, "Other"), title: "b.pdf")
        let was = rig.tab.order
        rig.pick(dir, "extra.pdf", Pdfs.text(1, "Extra"))
        rig.host.picker.during = {
            model.detach()
            model.attach(other.tab, other.viewer, other.host)
        }
        model.grid.select([3])

        await model.replace()

        XCTAssertEqual(rig.tab.pageCount, 4)
        XCTAssertNotEqual(rig.tab.text(3), was[3])
        XCTAssertEqual(other.tab.pageCount, 2)
        XCTAssertFalse(other.tab.isDirty)
        XCTAssertTrue(other.host.problems.isEmpty)
    }

    func test_aReplaceIsRefusedWhenTheFileChangedWhileThePickerWasUp() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(4)
        rig.pick(dir, "extra.pdf", Pdfs.text(1, "Extra"))
        rig.host.picker.during = { model.grid.remove([0, 1]) }
        model.grid.select([3])

        await model.replace()

        XCTAssertEqual(rig.tab.pageCount, 2)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Pages not changed"])
    }

    func test_pagesFromAFileGoToTheFileTheJobStartedOnWhenAnotherTabIsShownMeanwhile() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(2)
        let other = try PagesRig(Pdfs.text(1, "Other"), title: "b.pdf")
        rig.pick(dir, "extra.pdf", Pdfs.text(3, "Extra"))
        rig.host.picker.during = {
            model.detach()
            model.attach(other.tab, other.viewer, other.host)
        }

        await model.fromFile()

        XCTAssertEqual(rig.tab.pageCount, 5)
        XCTAssertEqual(other.tab.pageCount, 1)
    }

    func test_theTabsDocumentIsUntouchedWhileTheChangeRuns() async throws {
        let rig = try PagesRig(Pdfs.text(3))
        let running = PagesFlag(), release = DispatchSemaphore(value: 0)
        let job = Task { @MainActor in
            await PageJobs.applyAsync(rig.tab, rig.host, busy: "Adding", label: "Duplicate", { document in
                try PageOperations.duplicate(document, [0])
                running.raise()
                _ = release.wait(timeout: .now() + 20)
            }, status: "Done")
        }

        await waitUntil { running.isRaised }
        XCTAssertEqual(rig.tab.pageCount, 3)
        XCTAssertFalse(rig.tab.session.isDirty)
        release.signal()
        let done = await job.value

        XCTAssertTrue(done)
        XCTAssertEqual(rig.tab.pageCount, 4)
    }

    func test_aCancelledChangeLeavesTheTabAsItWas() async throws {
        let rig = try PagesRig(Pdfs.text(3))
        let before = rig.tab.session.current
        rig.host.cancelsBusy = true

        let done = await PageJobs.applyAsync(rig.tab, rig.host, busy: "Adding", label: "Duplicate", { document in
            try PageOperations.duplicate(document, [0])
            Thread.sleep(forTimeInterval: 0.3)
        }, status: "Done")

        XCTAssertFalse(done)
        XCTAssertEqual(rig.tab.session.current, before)
        XCTAssertFalse(rig.tab.isDirty)
    }

    func test_replacingWithNothingChosenDoesNothing() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        rig.pick(dir, "other.pdf", Pdfs.text(2, "Other"))

        await model.replace()

        XCTAssertEqual(rig.tab.pageCount, 3)
    }

    func test_aProtectedFileAsksForItsPasswordInASheet() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        rig.pick(dir, "locked.pdf", try PagesPdfs.locked(2))
        model.grid.select([0])

        let job = Task { await model.fromFile() }
        await waitUntil { model.asker.asking != nil }
        XCTAssertEqual(model.asker.asking?.kind, .password)
        model.asker.answer(password: "guess")
        await waitUntil { model.asker.asking?.problem != nil }
        XCTAssertEqual(model.asker.asking?.problem, "That password is not right.")
        model.asker.answer(password: "secret")
        await job.value

        XCTAssertEqual(rig.tab.pageCount, 5)
    }

    func test_givingUpOnTheQuestionLeavesTheFileAlone() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        rig.pick(dir, "locked.pdf", try PagesPdfs.locked(2))

        let job = Task { await model.fromFile() }
        await waitUntil { model.asker.asking != nil }
        model.asker.answer(password: nil)
        await job.value

        XCTAssertEqual(rig.tab.pageCount, 3)
        XCTAssertTrue(rig.host.problems.isEmpty)
    }

    func test_aQuestionStillOpenWhenThePanelLeavesCountsAsGivenUp() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        rig.pick(dir, "locked.pdf", try PagesPdfs.locked(2))

        let job = Task { await model.fromFile() }
        await waitUntil { model.asker.asking != nil }
        model.detach()
        await job.value

        XCTAssertNil(model.asker.asking)
        XCTAssertEqual(rig.tab.pageCount, 3)
    }

    func test_theSignedNoteFollowsTheFile() throws {
        let (model, _) = try attached()
        XCTAssertFalse(model.grid.isSigned)

        let signed = PagesToolModel()
        let rig = try PagesRig(Pdfs.signed(certified: false))
        signed.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertTrue(signed.grid.isSigned)
    }
}
