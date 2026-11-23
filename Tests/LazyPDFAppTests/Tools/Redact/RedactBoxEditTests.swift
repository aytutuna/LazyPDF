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
        model.selected = nil
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
}
