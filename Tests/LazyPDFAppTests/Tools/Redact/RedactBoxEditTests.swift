import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Moving and resizing a drawn box from the model: the keyboard steps and what they leave in the list, the history and the
// geometry of the page as it is shown now.

@MainActor
final class RedactBoxEditTests: XCTestCase {
    private static let line = "Write to ann@example.com today."

    private func attached(turned: Int = 0, letter: Bool = false) throws -> (model: RedactModel, rig: SecurityRig) {
        let bytes = letter ? try PdfFromText.create(Self.line, fonts: FakeFonts(), setup: PdfPageSetup(paper: .letter)).bytes : Pdfs.text(2, Self.line)
        let rig = try SecurityRig(bytes)
        rig.viewer.turned[0] = turned
        let model = RedactModel(fonts: FakeFonts(), images: FakeCodec())
        rig.attach(model)
        return (model, rig)
    }

    // A box from (50, 60) to (150, 90) of the unturned first page, selected.
    private func selectedBox(_ model: RedactModel, _ rig: SecurityRig, from: ViewPoint = ViewPoint(50, 60), to: ViewPoint = ViewPoint(150, 90)) throws -> MarkItem {
        model.setDrawing(true)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        func pointer(_ at: ViewPoint, _ pressed: Bool) -> PagePointer {
            PagePointer(page: 0, point: at, view: at, pressed: pressed, clicks: pressed ? 0 : 1)
        }
        tool.press(pointer(from, true))
        tool.move(pointer(to, true))
        tool.release(pointer(to, false))
        model.setDrawing(false)
        let box = try XCTUnwrap(model.marks.last)
        model.jump(box)
        return box
    }

    private func bounds(_ model: RedactModel) -> [Double] {
        let box = model.marks[0].mark.quads[0].bounds
        return [box.left, box.bottom, box.right, box.top]
    }

    func test_aReplaceSelectsTheNewItemAndAMissingOneIsLeftAlone() async throws {
        let (model, rig) = try attached()
        let old = try selectedBox(model, rig)
        let new = MarkItem(RedactionMark.fromRect(0, PdfRect(10, 10, 60, 40)), "Box", isBox: true)

        XCTAssertTrue(model.replace(old, new))
        XCTAssertEqual(model.selected, new.id)
        XCTAssertEqual(model.marks.map(\.id), [new.id])

        XCTAssertFalse(model.replace(old, MarkItem(RedactionMark.fromRect(0, PdfRect(1, 1, 5, 5)), "Box", isBox: true)))
        XCTAssertEqual(model.selected, new.id)
        XCTAssertEqual(model.marks.count, 1)
    }

    func test_anArrowMovesTheSelectedBoxAndSaysSo() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)

        model.nudge(.right)
        XCTAssertEqual(bounds(model), [51, 702, 151, 732])
        XCTAssertEqual(rig.host.statuses.last, "Box moved.")
        model.nudge(.up, large: true)
        XCTAssertEqual(bounds(model), [51, 712, 151, 742])
    }

    func test_theResizingStepsMoveTheRightAndBottomEdges() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)

        model.nudge(.wider)
        XCTAssertEqual(bounds(model), [50, 702, 151, 732])
        XCTAssertEqual(rig.host.statuses.last, "Box resized.")
        model.nudge(.narrower, large: true)
        XCTAssertEqual(bounds(model), [50, 702, 141, 732])
        model.nudge(.taller)
        XCTAssertEqual(bounds(model), [50, 701, 141, 732])
        model.nudge(.shorter, large: true)
        XCTAssertEqual(bounds(model), [50, 711, 141, 732])
    }

    func test_aRunOfStepsIsOneStepOfUndoThatBringsBackTheOriginalBox() async throws {
        let (model, rig) = try attached()
        let original = try selectedBox(model, rig)

        model.nudge(.right)
        model.nudge(.right)
        model.nudge(.down)
        XCTAssertEqual(bounds(model), [52, 701, 152, 731])
        XCTAssertTrue(model.canUndo)
        model.undo()

        XCTAssertEqual(model.marks.map(\.id), [original.id])
        XCTAssertEqual(bounds(model), [50, 702, 150, 732])
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertTrue(model.marks.isEmpty)
        XCTAssertFalse(model.canUndo)
    }

    func test_removeAfterAStepRemovesTheMovedBox() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)
        model.nudge(.left)

        model.removeSelected()

        XCTAssertTrue(model.marks.isEmpty)
        XCTAssertEqual(rig.host.notices.last?.title, "Mark removed")
        model.undo()
        XCTAssertEqual(bounds(model), [49, 702, 149, 732])
    }

    func test_aStepThatChangesNothingLeavesNoTraceInTheHistory() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig, from: ViewPoint(0, 0), to: ViewPoint(100, 30))
        let statuses = rig.host.statuses.count

        model.nudge(.left)
        model.nudge(.up, large: true)
        model.undo()

        XCTAssertEqual(rig.host.statuses.count, statuses)
        XCTAssertTrue(model.marks.isEmpty)
    }

    func test_onlyASelectedBoxIsEdited() async throws {
        let (model, rig) = try attached()
        model.query = "example"
        await model.markWords()
        let hit = model.marks[0]
        model.jump(hit)
        let before = model.marks.map(\.id)
        let statuses = rig.host.statuses.count

        XCTAssertFalse(model.canNudge)
        model.nudge(.right)

        XCTAssertEqual(model.marks.map(\.id), before)
        XCTAssertEqual(rig.host.statuses.count, statuses)
    }

    func test_aTurnedPageStepsInTheDirectionItShows() async throws {
        let (model, rig) = try attached(turned: 90)
        _ = try selectedBox(model, rig)
        XCTAssertEqual(bounds(model), [60, 50, 90, 150])

        model.nudge(.right)

        XCTAssertEqual(bounds(model), [60, 51, 90, 151])
    }

    func test_aPageTurnedAfterTheBoxWasDrawnIsStepsByItsNewGeometry() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)
        XCTAssertEqual(bounds(model), [50, 702, 150, 732])

        rig.viewer.turned[0] = 90
        PageOperations.rotate(rig.tab.document, [0], 90)
        try rig.tab.commit("Rotate")
        await waitUntil { !model.canUndo }
        model.nudge(.right)

        XCTAssertEqual(bounds(model), [50, 703, 150, 733])
    }

    func test_theRedactedAreaIsTheBoxAsLastMoved() async throws {
        func run(moves: Int) async throws -> String {
            let (model, rig) = try attached(letter: true)
            model.query = "example"
            await model.markWords()
            let text = model.marks[0].mark.quads[0].bounds
            model.clearMarks()
            _ = try selectedBox(model, rig, from: ViewPoint(text.left - 2, 792 - text.top - 2), to: ViewPoint(text.right + 2, 792 - text.bottom + 2))
            for _ in 0..<moves { model.nudge(.down, large: true) }

            await model.action!.run()

            return try TextCache(PdfDocument.open(try XCTUnwrap(rig.host.openedNew.first).pdf)).get(0).text
        }

        let covered = try await run(moves: 0)
        let moved = try await run(moves: 3)

        XCTAssertFalse(covered.contains("example"))
        XCTAssertTrue(moved.contains("example"))
    }

    func test_aBoxIsLeftAloneWhileTheCopyIsBeingMade() async throws {
        let (model, rig) = try attached()
        let box = try selectedBox(model, rig)
        var during: [MarkItem] = []
        rig.host.whileBusy = {
            XCTAssertTrue(model.working)
            model.nudge(.right)
            model.boxEdited(box, to: ViewRect(10, 10, 50, 30), rig.viewer.geometry(0), resized: false)
            model.undo()
            during = model.marks
        }

        await model.action!.run()

        XCTAssertEqual(during.map(\.id), [box.id])
        XCTAssertFalse(rig.host.statuses.contains("Box moved."))
    }

    func test_putItBackLeavesAChangedListAloneSoNoRowIsTwice() async throws {
        let (model, rig) = try attached()
        let box = try selectedBox(model, rig)

        model.remove(box)
        let back = try XCTUnwrap(rig.host.lastNoticeAction)
        model.undo()
        model.jump(model.marks[0])
        model.nudge(.right)
        back.run()

        XCTAssertEqual(model.marks.count, 1)
        XCTAssertEqual(Set(model.marks.map(\.row)).count, 1)
        XCTAssertEqual(rig.host.statuses.last, "The marks changed since. Use Undo in the list.")
    }

    // MARK: The tool

    private func frame(_ rig: SecurityRig) -> ViewRect? {
        guard case .rect(let rect)? = rig.viewer.overlay(0).item("redact.edit.frame")?.shape else { return nil }
        return rect
    }

    private func pointer(_ at: ViewPoint, pressed: Bool, touch: Bool = false) -> PagePointer {
        PagePointer(page: 0, point: at, view: at, pressed: pressed, clicks: pressed ? 1 : 0, touch: touch)
    }

    private func drag(_ tool: PagePointerTool, from: ViewPoint, to: ViewPoint) {
        tool.press(pointer(from, pressed: true))
        tool.move(pointer(to, pressed: true))
        tool.release(pointer(to, pressed: false))
    }

    func test_aSelectedBoxGetsTheToolAndLettingItGoTakesItAway() async throws {
        let (model, rig) = try attached()
        let original = try selectedBox(model, rig)
        XCTAssertNotNil(rig.viewer.pointerTool)
        model.jump(original)
        XCTAssertNil(rig.viewer.pointerTool)
        model.jump(original)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        XCTAssertFalse(model.drawing)
        XCTAssertEqual(frame(rig), ViewRect(50, 60, 100, 30))
        XCTAssertNotNil(rig.viewer.overlay(0).item("redact.edit.grip.7"))
        model.jump(original)

        XCTAssertNil(model.selected)
        XCTAssertNil(rig.viewer.pointerTool)
        XCTAssertNil(frame(rig))
        model.jump(original)
        XCTAssertTrue(rig.viewer.pointerTool === tool)
    }

    func test_theToolStaysWhileBoxesAreBeingDrawnAndGoesWhenBothEnd() async throws {
        let (model, rig) = try attached()
        let box = try selectedBox(model, rig)
        model.setDrawing(true)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        model.jump(box)
        XCTAssertTrue(rig.viewer.pointerTool === tool)
        XCTAssertNil(frame(rig))
        XCTAssertTrue(model.drawing)
        model.setDrawing(false)

        XCTAssertNil(rig.viewer.pointerTool)
        XCTAssertFalse(model.drawing)
    }

    func test_aHandleDragIsOneReplaceAndKeepsTheSameTool() async throws {
        let (model, rig) = try attached()
        let original = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        tool.press(pointer(ViewPoint(150, 90), pressed: true))
        tool.move(pointer(ViewPoint(170, 100), pressed: true))
        XCTAssertEqual(frame(rig), ViewRect(50, 60, 120, 40))
        XCTAssertEqual(bounds(model), [50, 702, 150, 732])
        tool.release(pointer(ViewPoint(170, 100), pressed: false))

        XCTAssertEqual(bounds(model), [50, 692, 170, 732])
        XCTAssertEqual(model.marks.count, 1)
        XCTAssertNotEqual(model.marks[0].id, original.id)
        XCTAssertEqual(model.selected, model.marks[0].id)
        XCTAssertTrue(rig.viewer.pointerTool === tool)
        XCTAssertEqual(frame(rig), ViewRect(50, 60, 120, 40))
        XCTAssertEqual(rig.host.statuses.last, "Box resized.")
        model.undo()
        XCTAssertEqual(model.marks.map(\.id), [original.id])
        XCTAssertEqual(bounds(model), [50, 702, 150, 732])
    }

    func test_aBodyDragMovesTheBox() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        drag(tool, from: ViewPoint(100, 75), to: ViewPoint(110, 80))

        XCTAssertEqual(bounds(model), [60, 697, 160, 727])
        XCTAssertEqual(rig.host.statuses.last, "Box moved.")
    }

    func test_aDragThatEndsWhereItBeganChangesNothing() async throws {
        let (model, rig) = try attached()
        let original = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        drag(tool, from: ViewPoint(100, 75), to: ViewPoint(100, 75))

        XCTAssertEqual(model.marks.map(\.id), [original.id])
        XCTAssertEqual(frame(rig), ViewRect(50, 60, 100, 30))
    }

    func test_aCancelledDragLeavesTheListAndPutsTheFrameBack() async throws {
        let (model, rig) = try attached()
        let original = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        tool.press(pointer(ViewPoint(100, 75), pressed: true))
        tool.move(pointer(ViewPoint(130, 95), pressed: true))
        XCTAssertEqual(frame(rig), ViewRect(80, 80, 100, 30))
        tool.cancel()
        tool.release(pointer(ViewPoint(130, 95), pressed: false))

        XCTAssertEqual(model.marks.map(\.id), [original.id])
        XCTAssertEqual(frame(rig), ViewRect(50, 60, 100, 30))
    }

    func test_handInLetsADragEndWhereItIs() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        tool.press(pointer(ViewPoint(100, 75), pressed: true))
        tool.move(pointer(ViewPoint(110, 75), pressed: true))

        XCTAssertTrue(model.handIn())
        let ids = model.marks.map(\.id)
        tool.release(pointer(ViewPoint(140, 75), pressed: false))

        XCTAssertEqual(bounds(model), [60, 702, 160, 732])
        XCTAssertEqual(model.marks.map(\.id), ids)
        model.undo()
        XCTAssertEqual(bounds(model), [50, 702, 150, 732])
    }

    func test_aListChangeDuringADragDropsTheDrag() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        tool.press(pointer(ViewPoint(100, 75), pressed: true))
        tool.move(pointer(ViewPoint(110, 75), pressed: true))

        model.clearMarks()
        tool.release(pointer(ViewPoint(140, 75), pressed: false))

        XCTAssertTrue(model.marks.isEmpty)
        XCTAssertNil(frame(rig))
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_aFingerIsTheToolsOnlyOverTheSelectedBoxUnlessBoxesAreBeingDrawn() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        let away = ViewPoint(400, 400)

        // What the viewer loses while a box is selected on a phone is its text selection and double tap; a finger elsewhere still scrolls.
        XCTAssertTrue(tool.takes(pointer(ViewPoint(150, 90), pressed: true, touch: true)))
        XCTAssertTrue(tool.takes(pointer(ViewPoint(100, 75), pressed: true, touch: true)))
        XCTAssertFalse(tool.takes(pointer(away, pressed: true, touch: true)))
        XCTAssertFalse(tool.takes(pointer(away, pressed: true)))
        model.setDrawing(true)
        XCTAssertTrue(tool.takes(pointer(away, pressed: true, touch: true)))
        XCTAssertTrue(tool.takes(pointer(away, pressed: true)))
    }

    func test_aPressAwayFromTheBoxDrawsOnlyWhileDrawingIsOn() async throws {
        let (model, rig) = try attached()
        let original = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        drag(tool, from: ViewPoint(300, 300), to: ViewPoint(400, 350))
        XCTAssertEqual(model.marks.count, 1)
        model.setDrawing(true)
        drag(tool, from: ViewPoint(300, 300), to: ViewPoint(400, 350))

        XCTAssertEqual(model.marks.count, 2)
        XCTAssertEqual(model.selected, original.id)
        XCTAssertNotNil(frame(rig))
    }

    func test_theToolLeavesKeysToTheViewer() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        for key in [ViewerKey.left, .right, .up, .down, .escape, .delete] {
            XCTAssertFalse(tool.key(key, modifiers: []))
        }
    }

    func test_aHitRowStaysSelectedWhenTheModelTakesItsOwnToolOff() async throws {
        let state = TabToolState()
        let rig = try SecurityRig(Pdfs.text(2, Self.line))
        let model = RedactModel(fonts: FakeFonts(), images: FakeCodec(), state: state)
        rig.attach(model)
        _ = try selectedBox(model, rig)
        let marks = try XCTUnwrap(state.redact[rig.tab]).marks
        marks.add([MarkItem(RedactionMark.fromRect(0, PdfRect(400, 100, 420, 120)), "hit", value: RedactionValueMatch(0, 2, .comment, 0, 3, "abc", .word))])
        let hit = try XCTUnwrap(model.marks.first { $0.value != nil })

        model.jump(hit)
        XCTAssertNil(rig.viewer.pointerTool)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(model.selected, hit.id)
    }

    func test_aDragThatIsRefusedWhileTheCopyIsBeingMadePutsTheFrameBackOnTheBox() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        var shown: ViewRect?
        var count = 0
        rig.host.whileBusy = {
            self.drag(tool, from: ViewPoint(100, 75), to: ViewPoint(130, 95))
            shown = self.frame(rig)
            model.setDrawing(true)
            self.drag(tool, from: ViewPoint(300, 300), to: ViewPoint(400, 350))
            count = model.marks.count
        }

        await model.action!.run()

        XCTAssertEqual(shown, ViewRect(50, 60, 100, 30))
        XCTAssertEqual(count, 1)
    }

    func test_theViewerTakingThePointerBackLetsTheBoxGo() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)
        model.setDrawing(true)

        rig.viewer.pointerTool = nil
        await waitUntil { model.selected == nil }

        XCTAssertFalse(model.drawing)
        XCTAssertNil(frame(rig))
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_theFrameAndLaterDragsFollowAPageThatWasTurned() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        tool.press(pointer(ViewPoint(100, 75), pressed: true))
        tool.move(pointer(ViewPoint(110, 80), pressed: true))

        rig.viewer.turned[0] = 90
        PageOperations.rotate(rig.tab.document, [0], 90)
        try rig.tab.commit("Rotate")
        await waitUntil { self.frame(rig) == ViewRect(702, 50, 30, 100) }
        tool.release(pointer(ViewPoint(110, 80), pressed: false))
        XCTAssertEqual(bounds(model), [50, 702, 150, 732])

        drag(tool, from: ViewPoint(717, 100), to: ViewPoint(727, 100))
        XCTAssertEqual(bounds(model), [50, 712, 150, 742])
    }

    func test_nothingIsLeftOnThePageOnceThePanelIsDetached() async throws {
        let (model, rig) = try attached()
        _ = try selectedBox(model, rig)
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        tool.press(pointer(ViewPoint(100, 75), pressed: true))

        model.detach()
        rig.viewer.endToolMarks(prefix: "redact.")
        tool.cancel()

        XCTAssertNil(frame(rig))
        XCTAssertNil(rig.viewer.overlay(0).item("redact.edit.grip.0"))
    }

    func test_aMovedBoxStaysInItsRowSoTheRowKeepsItsFocus() async throws {
        let (model, rig) = try attached()
        let original = try selectedBox(model, rig)

        model.nudge(.right)
        model.nudge(.wider)
        XCTAssertEqual(model.marks.map(\.row), [original.row])
        XCTAssertNotEqual(model.marks[0].id, original.id)

        model.undo()
        XCTAssertEqual(model.marks.map(\.row), [original.row])
    }

    func test_everyStepOfTheKeyboardAndOfAScreenReaderMovesTheBoxByItsOwnAmount() async throws {
        let steps: [(BoxMove, [Double])] = [
            (.left, [49, 702, 149, 732]), (.right, [51, 702, 151, 732]), (.up, [50, 703, 150, 733]), (.down, [50, 701, 150, 731]),
            (.wider, [50, 702, 151, 732]), (.narrower, [50, 702, 149, 732]), (.taller, [50, 701, 150, 732]), (.shorter, [50, 703, 150, 732]),
        ]
        XCTAssertEqual(Set(steps.map(\.0)), Set(BoxMove.allCases))
        for (move, expected) in steps {
            let (model, rig) = try attached()
            _ = try selectedBox(model, rig)

            model.nudge(move)

            XCTAssertEqual(bounds(model), expected, "\(move)")
        }
    }
}
