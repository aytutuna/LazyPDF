import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/Pages/OrganizeViewTests.cs, which builds the view on a hidden window and feeds its
// handlers real events. Here the model is driven directly. Left out because they test WPF itself: the focus tests (keys on the bar,
// a job that disables the view), the double click on the hover bar, pressing one of several selected pages, and the virtualized
// TilePanel. The keys are the shortcuts of the buttons, which the view tests draw. A double tap is `open`.

@MainActor
final class OrganizeModelTests: XCTestCase {
    private func attached(_ pages: Int = 6, bytes: [UInt8]? = nil) throws -> (model: OrganizeModel, rig: PagesRig) {
        let rig = try PagesRig(bytes ?? Pdfs.text(pages))
        let model = OrganizeModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        return (model, rig)
    }

    func test_theButtonHoldsTheStageAndDoneGivesItBack() throws {
        let rig = try PagesRig(Pdfs.text(6))
        let panel = PagesToolModel()
        panel.attach(rig.tab, rig.viewer, rig.host)

        panel.openOrganize()
        XCTAssertTrue(rig.host.holding)
        let view = try XCTUnwrap(panel.organize)
        view.done()
        XCTAssertFalse(rig.host.holding)
        XCTAssertNil(panel.organize)

        panel.openOrganize()
        XCTAssertTrue(rig.host.holding)
        panel.detach()
        XCTAssertFalse(rig.host.holding)
    }

    func test_aQuestionFromTheStageIsAskedInTheSheetOfThePanel() async throws {
        let dir = TempDir(self)
        let rig = try PagesRig(Pdfs.text(3))
        let panel = PagesToolModel()
        panel.attach(rig.tab, rig.viewer, rig.host)
        panel.openOrganize()
        let organize = try XCTUnwrap(panel.organize)
        XCTAssertTrue(organize.asker === panel.asker)
        let file = dir.file("locked.pdf", try PagesPdfs.locked())

        let job = Task { await organize.insertFiles([ToolFile(url: file)], at: 1) }
        await waitUntil { panel.asker.asking != nil }
        panel.asker.answer(password: "secret")
        await job.value

        XCTAssertEqual(rig.tab.pageCount, 6)
    }

    func test_everyPageIsATileAndTheSliderResizesThemAll() throws {
        let (model, _) = try attached(40)
        let before = model.grid.cells[0].width

        model.setTileSize(240)

        XCTAssertEqual(model.grid.cells.count, 40)
        XCTAssertGreaterThan(model.grid.cells[0].width, before)
        model.setTileSize(1000)
        XCTAssertEqual(model.tileSize, 320)
    }

    func test_controlAndShiftSelectAndCtrlASelectsAll() throws {
        let (model, _) = try attached()

        model.grid.selectAll()
        XCTAssertEqual(model.grid.selected.count, 6)
        XCTAssertEqual(model.grid.summary, "6 of 6 selected")

        model.grid.select([1])
        model.grid.toggle(4)
        XCTAssertEqual(model.grid.selection, [1, 4])
        model.grid.toggle(4)
        XCTAssertEqual(model.grid.selection, [1])

        model.grid.extend(to: 2)
        XCTAssertEqual(model.grid.selection, [2, 3, 4])
    }

    func test_aPlainClickChoosesOnePageAndShiftExtendsFromIt() throws {
        let (model, _) = try attached()

        model.grid.selectAll()
        model.grid.choose(4)
        XCTAssertEqual(model.grid.selection, [4])

        model.grid.extend(to: 1)
        XCTAssertEqual(model.grid.selection, [1, 2, 3, 4])
        model.grid.extend(to: 5)
        XCTAssertEqual(model.grid.selection, [4, 5])

        model.grid.toggle(0)
        model.grid.extend(to: 2)
        XCTAssertEqual(model.grid.selection, [0, 1, 2])
    }

    func test_selectNoneEmptiesTheChoiceSoAJobCoversEveryPage() throws {
        let (model, _) = try attached()
        model.grid.selectAll()
        XCTAssertEqual(model.grid.selectedOrAll.count, 6)

        model.grid.selectNone()

        XCTAssertTrue(model.grid.selected.isEmpty)
        XCTAssertEqual(model.grid.summary, "6 pages")
    }

    func test_aDragThatLandsAfterThePagesWereRemovedMovesNothing() throws {
        let (model, rig) = try attached()
        model.grid.remove([2, 3, 4, 5])
        let was = rig.tab.order

        model.grid.dragging = [4, 5]
        model.grid.mark(0, after: false)
        model.grid.dropPages()

        XCTAssertEqual(rig.tab.order, was)
        XCTAssertTrue(model.grid.dragging.isEmpty)
    }

    func test_aDragLeftOverFromBeforeAnEditIsForgotten() throws {
        let (model, _) = try attached()
        model.grid.dragging = [3]

        model.grid.remove([0])

        XCTAssertTrue(model.grid.dragging.isEmpty)
    }

    func test_deleteRemovesTheSelectedPagesInOneStepThatUndoBringsBack() async throws {
        let (model, rig) = try attached()
        let was = rig.tab.order
        model.grid.select([1, 2])

        model.remove()

        XCTAssertEqual(rig.tab.order, [was[0], was[3], was[4], was[5]])
        XCTAssertEqual(model.grid.cells.count, 4)
        try rig.tab.undo()
        await waitUntil { model.grid.cells.count == 6 }
        XCTAssertEqual(rig.tab.order, was)
    }

    func test_everyPageCannotBeDeleted() throws {
        let (model, rig) = try attached(3)

        model.grid.selectAll()
        model.remove()

        XCTAssertEqual(rig.tab.pageCount, 3)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Cannot delete every page"])
    }

    func test_theBarTurnsTheSelectionAndTheHoverBarTurnsOnePage() throws {
        let (model, rig) = try attached()
        model.grid.select([0, 2])

        model.turnSelection(90)
        XCTAssertEqual(rig.tab.document.pages[0].rotate, 90)
        XCTAssertEqual(rig.tab.document.pages[2].rotate, 90)
        XCTAssertEqual(rig.tab.document.pages[1].rotate, 0)
        XCTAssertEqual(model.grid.selection, [0, 2])

        model.turnSelection(-90)
        XCTAssertEqual(rig.tab.document.pages[0].rotate, 0)

        model.turn(model.grid.target(3), 90)
        XCTAssertEqual(rig.tab.document.pages[3].rotate, 90)
        XCTAssertEqual(rig.tab.document.pages[2].rotate, 0)
    }

    func test_aMenuOnASelectedPageIsAboutTheWholeSelectionAndOnAnotherOneAboutItAlone() throws {
        let (model, _) = try attached()
        model.grid.select([1, 2])

        XCTAssertEqual(model.grid.target(2), [1, 2])
        XCTAssertEqual(model.grid.target(4), [4])
    }

    func test_draggingPagesMarksTheGapAndDropMovesThemAsOneStep() async throws {
        let (model, rig) = try attached()
        let was = rig.tab.order
        model.grid.dragging = [0, 1]

        model.grid.mark(4, after: false)
        XCTAssertTrue(model.grid.cells[4].dropBefore)
        model.grid.mark(4, after: true)
        XCTAssertFalse(model.grid.cells[4].dropBefore)
        XCTAssertTrue(model.grid.cells[4].dropAfter)

        model.grid.mark(4, after: false)
        model.grid.dropPages()

        XCTAssertEqual(rig.tab.order, [was[2], was[3], was[0], was[1], was[4], was[5]])
        XCTAssertEqual(model.grid.selection, [2, 3])
        XCTAssertTrue(model.grid.cells.allSatisfy { !$0.dropBefore && !$0.dropAfter })
        try rig.tab.undo()
        XCTAssertEqual(rig.tab.order, was)
    }

    func test_leavingTheGridClearsTheMark() throws {
        let (model, _) = try attached()

        model.grid.mark(2, after: true)
        model.grid.unmark()

        XCTAssertTrue(model.grid.cells.allSatisfy { !$0.dropBefore && !$0.dropAfter })
        XCTAssertEqual(model.grid.dropIndex, 6)
    }

    func test_aMarkedGapIsWhereTheDropGoes() throws {
        let (model, _) = try attached()

        model.grid.mark(2, after: false)
        XCTAssertEqual(model.grid.dropIndex, 2)
        model.grid.mark(2, after: true)
        XCTAssertEqual(model.grid.dropIndex, 3)
    }

    func test_aDroppedFileGoesInBetweenThePagesAsOneStep() async throws {
        let dir = TempDir(self)
        let file = dir.file("extra.pdf", Pdfs.text(2, "Dropped"))
        let source = try PdfDocument.open(Pdfs.text(2, "Dropped"))
        let (model, rig) = try attached(4)
        let was = rig.tab.order

        await model.insertFiles([ToolFile(url: file)], at: 2)

        XCTAssertEqual(rig.tab.pageCount, 6)
        XCTAssertEqual(rig.tab.text(0), was[0])
        XCTAssertEqual(rig.tab.text(1), was[1])
        XCTAssertEqual(rig.tab.text(2), String(bytes: source.pages[0].contents(), encoding: .isoLatin1))
        XCTAssertEqual(rig.tab.text(4), was[2])
        XCTAssertEqual(model.grid.selection, [2, 3])
        try rig.tab.undo()
        XCTAssertEqual(rig.tab.order, was)
    }

    func test_somethingThatIsNotAPdfIsRefused() async throws {
        let (model, rig) = try attached(2)

        await model.insertFiles([ToolFile(url: URL(fileURLWithPath: "/notes.txt"))], at: 1)

        XCTAssertEqual(rig.tab.pageCount, 2)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Not a PDF"])
    }

    func test_copyThenPasteMovesPagesBetweenTabs() async throws {
        let (from, fromRig) = try attached(4)
        let fromOrder = fromRig.tab.order
        let toRig = try PagesRig(Pdfs.text(2, "Other"))
        let to = OrganizeModel()
        to.attach(toRig.tab, toRig.viewer, toRig.host)
        let toOrder = toRig.tab.order
        from.grid.select([1, 2])
        PageClipboard.shared.set([], 0)

        await from.copy()

        XCTAssertEqual(PageClipboard.shared.count, 2)
        XCTAssertEqual(fromRig.tab.order, fromOrder)
        to.grid.select([0])
        XCTAssertTrue(to.canPaste)

        await to.paste()

        XCTAssertEqual(toRig.tab.pageCount, 4)
        XCTAssertEqual(toRig.tab.text(0), toOrder[0])
        XCTAssertEqual(toRig.tab.text(1), fromOrder[1])
        XCTAssertEqual(toRig.tab.text(2), fromOrder[2])
        XCTAssertEqual(toRig.tab.text(3), toOrder[1])
        XCTAssertEqual(to.grid.selection, [1, 2])
        try toRig.tab.undo()
        XCTAssertEqual(toRig.tab.order, toOrder)
    }

    func test_cutTakesThePagesOutAsOneStepAndTheyCanBePastedBack() async throws {
        let (model, rig) = try attached(5)
        let was = rig.tab.order
        model.grid.select([1, 2])

        await model.cut()
        XCTAssertEqual(rig.tab.order, [was[0], was[3], was[4]])

        model.grid.select([0])
        await model.paste()
        XCTAssertEqual(rig.tab.order, was)

        try rig.tab.undo()
        try rig.tab.undo()
        XCTAssertEqual(rig.tab.order, was)
    }

    func test_aPasteWithNothingCopiedDoesNothing() async throws {
        let (model, rig) = try attached(2)
        let revision = rig.tab.revision
        PageClipboard.shared.set([], 0)

        await model.paste()

        XCTAssertEqual(rig.tab.revision, revision)
    }

    func test_aBlankPageGoesAfterTheSelectionAndDuplicateKeepsBothCopiesSelected() async throws {
        let (model, rig) = try attached(3)
        let was = rig.tab.order
        model.grid.select([0])

        model.blank()
        XCTAssertEqual(rig.tab.pageCount, 4)
        XCTAssertEqual(model.grid.selection, [1])

        model.grid.select([0])
        await model.duplicate()
        XCTAssertEqual(rig.tab.text(0), was[0])
        XCTAssertEqual(rig.tab.text(1), was[0])
        XCTAssertEqual(model.grid.selection, [0, 1])
    }

    func test_extractOpensANewFileAndLeavesTheDocumentAlone() async throws {
        let (model, rig) = try attached(4)
        let revision = rig.tab.revision
        model.grid.select([1, 3])

        await model.extract()

        XCTAssertEqual(rig.host.openedNew.map(\.title), ["a extract.pdf"])
        XCTAssertEqual(rig.tab.revision, revision)
    }

    func test_aDocumentThatLimitsCopyingCannotBeCopiedFrom() async throws {
        let rig = try PagesRig(Pdfs.restricted(.print))
        let model = OrganizeModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        model.grid.select([0])
        PageClipboard.shared.set([1], 7)

        await model.copy()

        XCTAssertEqual(PageClipboard.shared.count, 7)
        XCTAssertEqual(rig.host.problems.map(\.title), ["File is protected"])
    }

    func test_theWhereBoxLetsABlankPageBecomeTheFirstPage() throws {
        let (model, rig) = try attached(3)
        let was = rig.tab.order
        model.grid.select([2])
        model.place = .atStart

        model.blank()

        XCTAssertEqual(rig.tab.pageCount, 4)
        XCTAssertEqual(rig.tab.text(1), was[0])
        XCTAssertEqual(model.grid.selection, [0])
    }

    func test_aFileDroppedOnTheBarGoesToTheEnd() async throws {
        let dir = TempDir(self)
        let file = dir.file("extra.pdf", Pdfs.text(1, "Dropped"))
        let (model, rig) = try attached(2)

        await model.insertFiles([ToolFile(url: file)], at: model.grid.cells.count)

        XCTAssertEqual(rig.tab.pageCount, 3)
    }

    func test_copyingOutOfAnEncryptedFileSaysTheCopyIsNotProtected() async throws {
        let rig = try PagesRig(Pdfs.restricted(.all))
        let model = OrganizeModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        model.grid.select([0])
        PageClipboard.shared.set([], 0)

        await model.copy()

        XCTAssertEqual(PageClipboard.shared.count, 1)
        XCTAssertEqual(rig.host.notices.map(\.title), ["Copy is not protected"])
    }

    func test_aDoubleTapOnAPageShowsItAndLeaves() throws {
        let (model, rig) = try attached(4)
        var closed = 0
        model.onClose = { closed += 1 }

        model.open(3)

        XCTAssertEqual(rig.viewer.sent, [3])
        XCTAssertEqual(closed, 1)
    }

    func test_aChangeFromElsewhereMakesTheCellsAgainAndChoosesNothing() async throws {
        let (model, rig) = try attached(3)
        model.grid.select([1])
        let old = model.grid.cells[0]

        PageOperations.rotate(rig.tab.document, [0], 90)
        try rig.tab.commit("Rotate pages")
        await waitUntil { model.grid.cells[0] !== old }

        XCTAssertTrue(model.grid.selected.isEmpty)
    }

    func test_aChoiceOfPagesThatAreGoneIsDropped() throws {
        let (model, _) = try attached(3)

        model.grid.select([1, 7, -1])

        XCTAssertEqual(model.grid.selection, [1])
    }
}
