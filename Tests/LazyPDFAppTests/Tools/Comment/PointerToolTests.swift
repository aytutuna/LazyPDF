import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/comment/PointerToolTests.cs: the two pointer tools of the panel, drawing a new mark,
// and selecting, moving and resizing one that is there. The Windows tests count the children of the overlay canvas; these count
// the overlay's items. The viewer is the panels' PanelViewer, whose pages are 612 by 792 points on the first page.

@MainActor
final class PointerToolTests: XCTestCase {
    private func press(_ at: ViewPoint, clicks: Int = 1, page: Int = 0) -> PagePointer {
        PagePointer(page: page, point: at, view: at, pressed: true, clicks: clicks)
    }

    private func drag(_ at: ViewPoint, page: Int = 0) -> PagePointer {
        PagePointer(page: page, point: at, view: at, pressed: true, clicks: 0)
    }

    private func hover(_ at: ViewPoint, page: Int = 0) -> PagePointer {
        PagePointer(page: page, point: at, view: at, pressed: false, clicks: 0)
    }

    private final class Drawn {
        var marks: [(tool: MarkTool, page: Int, points: [ViewPoint])] = []
    }

    private func drawing(_ tool: MarkTool, pages: Int = 1) throws -> (tool: DrawTool, viewer: PanelViewer, drawn: Drawn) {
        let f = try CommentFixture(pages: pages)
        let viewer = PanelViewer(f.tab)
        let drawn = Drawn()
        let draw = DrawTool(viewer: viewer, tool: tool, style: { markRed }, done: { drawn.marks.append(($0, $1, $2)) })
        return (draw, viewer, drawn)
    }

    func test_aDragDrawsAPreviewAndGivesBothEndsOnRelease() throws {
        let (tool, viewer, drawn) = try drawing(.rectangle)

        tool.press(press(markPt(50, 60)))
        tool.move(drag(markPt(150, 120)))
        XCTAssertEqual(viewer.overlay(0).items.count, 1)
        tool.release(drag(markPt(150, 120)))

        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].tool, .rectangle)
        XCTAssertEqual(drawn.marks[0].points, [markPt(50, 60), markPt(150, 120)])
    }

    func test_aClickWithoutADragDrawsNothingForAShape() throws {
        let (tool, viewer, drawn) = try drawing(.oval)

        tool.press(press(markPt(50, 60)))
        tool.release(drag(markPt(51, 60)))

        XCTAssertTrue(drawn.marks.isEmpty)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_aClickToolFinishesOnRelease() throws {
        for kind in [MarkTool.note, .stamp, .attach] {
            let (tool, _, drawn) = try drawing(kind)

            tool.press(press(markPt(70, 80)))
            XCTAssertTrue(drawn.marks.isEmpty)
            tool.release(drag(markPt(70, 80)))

            XCTAssertEqual(drawn.marks.count, 1)
            XCTAssertEqual(drawn.marks[0].points, [markPt(70, 80)])
        }
    }

    func test_aClickWithTheTextBoxMakesABoxOfTheUsualSize() throws {
        let (tool, _, drawn) = try drawing(.textBox)

        tool.press(press(markPt(70, 80)))
        tool.release(drag(markPt(70, 80)))

        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].points, [markPt(70, 80), markPt(230, 128)])
    }

    func test_aPolygonTakesOneCornerPerClickAndEndsOnADoubleClick() throws {
        let (tool, viewer, drawn) = try drawing(.polygon)

        tool.press(press(markPt(10, 10)))
        tool.release(drag(markPt(10, 10)))
        tool.move(hover(markPt(100, 10)))
        tool.press(press(markPt(100, 10)))
        tool.release(drag(markPt(100, 10)))
        tool.press(press(markPt(100, 100)))
        tool.release(drag(markPt(100, 100)))
        XCTAssertTrue(drawn.marks.isEmpty)
        XCTAssertEqual(viewer.overlay(0).items.count, 1)
        tool.press(press(markPt(100, 100), clicks: 2))

        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].points, [markPt(10, 10), markPt(100, 10), markPt(100, 100)])
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_aPolygonClosesWhenTheFirstCornerIsClickedAgain() throws {
        let (tool, _, drawn) = try drawing(.cloud)
        for corner in [markPt(10, 10), markPt(100, 10), markPt(100, 100)] {
            tool.press(press(corner))
            tool.release(drag(corner))
        }

        tool.press(press(markPt(12, 11)))

        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].points.count, 3)
    }

    func test_aPolygonOfTwoCornersIsDropped() throws {
        let (tool, viewer, drawn) = try drawing(.polygon)
        tool.press(press(markPt(10, 10)))
        tool.release(drag(markPt(10, 10)))
        tool.press(press(markPt(100, 10)))
        tool.release(drag(markPt(100, 10)))

        tool.press(press(markPt(100, 10), clicks: 2))

        XCTAssertTrue(drawn.marks.isEmpty)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_aPolygonWithCornersEnoughIsEndedByFinishShape() throws {
        let (tool, _, drawn) = try drawing(.polygon)
        for corner in [markPt(10, 10), markPt(100, 10)] {
            tool.press(press(corner))
            tool.release(drag(corner))
        }
        XCTAssertFalse(tool.canFinish)
        tool.finishShape()
        XCTAssertTrue(drawn.marks.isEmpty)

        tool.press(press(markPt(100, 100)))
        tool.release(drag(markPt(100, 100)))
        XCTAssertTrue(tool.canFinish)
        tool.finishShape()

        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].points.count, 3)
        XCTAssertFalse(tool.started)
    }

    func test_freehandKeepsEveryPointOfTheDrag() throws {
        let (tool, _, drawn) = try drawing(.pencil)

        tool.press(press(markPt(10, 10)))
        tool.move(drag(markPt(20, 14)))
        tool.move(drag(markPt(30, 22)))
        tool.release(drag(markPt(30, 22)))

        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].points, [markPt(10, 10), markPt(20, 14), markPt(30, 22)])
    }

    func test_aCalloutNeedsADragAndLeavesTwoPreviewShapes() throws {
        let (tool, viewer, drawn) = try drawing(.callout)

        tool.press(press(markPt(100, 100)))
        tool.move(drag(markPt(300, 200)))
        XCTAssertEqual(viewer.overlay(0).items.count, 2)
        tool.release(drag(markPt(300, 200)))

        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].points, [markPt(100, 100), markPt(300, 200)])
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_cancellingDropsWhatWasStarted() throws {
        let (tool, viewer, drawn) = try drawing(.line)
        tool.press(press(markPt(10, 10)))
        tool.move(drag(markPt(90, 90)))

        tool.cancel()
        tool.release(drag(markPt(90, 90)))

        XCTAssertTrue(drawn.marks.isEmpty)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_aDrawnPolygonKnowsItHasStartedUntilItIsCancelled() throws {
        let (tool, viewer, _) = try drawing(.polygon)
        XCTAssertFalse(tool.started)

        tool.press(press(markPt(10, 10)))
        tool.release(drag(markPt(10, 10)))
        XCTAssertTrue(tool.started)

        tool.cancel()
        XCTAssertFalse(tool.started)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_escapeDropsAShapeThatWasStartedAndIsLeftAloneOtherwise() throws {
        let (tool, _, drawn) = try drawing(.polygon)
        XCTAssertFalse(tool.key(.escape, modifiers: []))

        tool.press(press(markPt(10, 10)))
        tool.release(drag(markPt(10, 10)))

        XCTAssertTrue(tool.key(.escape, modifiers: []))
        XCTAssertFalse(tool.started)
        XCTAssertTrue(drawn.marks.isEmpty)
        XCTAssertFalse(tool.key(.delete, modifiers: []))
    }

    // The edit tool

    private func editing(pages: Int = 1) throws -> (tool: EditTool, f: CommentFixture, viewer: PanelViewer, made: PdfAnnotation) {
        let f = try CommentFixture(pages: pages)
        let viewer = PanelViewer(f.tab)
        let made = try f.marker.add(.textBox, 0, [markPt(100, 100), markPt(200, 160)], markRed, "Look")
        try f.tab.commit("Text box")
        return (EditTool(viewer: viewer, marker: { f.marker }), f, viewer, made)
    }

    func test_aPressOnAMarkSelectsItAndShowsAFrameWithEightHandles() throws {
        let (tool, _, viewer, made) = try editing()
        var raised = 0
        tool.selectionChanged = { raised += 1 }

        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))

        XCTAssertEqual(tool.current?.reference?.number, made.reference?.number)
        XCTAssertEqual(viewer.overlay(0).items.count, 9)
        XCTAssertEqual(raised, 1)
    }

    func test_redrawingAfterTheMarksPageWentAwayDrawsNothing() throws {
        let f = try CommentFixture(pages: 2)
        let viewer = PanelViewer(f.tab)
        try f.marker.add(.textBox, 1, [markPt(100, 100), markPt(200, 160)], markRed, "Look")
        try f.tab.commit("Text box")
        let tool = EditTool(viewer: viewer, marker: { f.marker })
        tool.select(f.marks(1)[0])
        try PageOperations.delete(f.document, [1])
        try f.tab.commit("Delete pages")

        tool.redraw()

        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_aPressOnNothingLetsGoOfTheSelection() throws {
        let (tool, _, viewer, _) = try editing()
        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))

        tool.press(press(markPt(400, 400)))

        XCTAssertNil(tool.current)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_draggingAMarkAsksForTheMoveOnlyOnRelease() throws {
        let (tool, _, _, _) = try editing()
        var moves: [(Double, Double)] = []
        tool.moved = { _, dx, dy in moves.append((dx, dy)) }

        tool.press(press(markPt(150, 130)))
        tool.move(drag(markPt(170, 150)))
        XCTAssertTrue(moves.isEmpty)
        tool.release(drag(markPt(170, 150)))

        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].0, 20)
        XCTAssertEqual(moves[0].1, 20)
    }

    func test_aClickWithoutMovingAsksForNothing() throws {
        let (tool, _, _, _) = try editing()
        var asked = 0
        tool.moved = { _, _, _ in asked += 1 }
        tool.resized = { _, _ in asked += 1 }

        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))

        XCTAssertEqual(asked, 0)
    }

    func test_draggingACornerHandleAsksForTheNewBox() throws {
        let (tool, _, _, _) = try editing()
        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))
        var boxes: [ViewRect] = []
        tool.resized = { _, box in boxes.append(box) }

        tool.press(press(markPt(200, 160)))
        tool.move(drag(markPt(260, 200)))
        tool.release(drag(markPt(260, 200)))

        XCTAssertEqual(boxes, [ViewRect(100, 100, 160, 100)])
    }

    func test_aMarkCannotBeResizedBelowASmallestSize() throws {
        let (tool, _, _, _) = try editing()
        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))
        var boxes: [ViewRect] = []
        tool.resized = { _, box in boxes.append(box) }

        tool.press(press(markPt(200, 160)))
        tool.move(drag(markPt(20, 20)))
        tool.release(drag(markPt(20, 20)))

        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].width, 8)
        XCTAssertEqual(boxes[0].height, 8)
    }

    func test_aDoubleClickAsksToEditTheText() throws {
        let (tool, _, _, made) = try editing()
        var asked: PdfAnnotation?
        tool.editRequested = { asked = $0 }

        tool.press(press(markPt(150, 130), clicks: 2))

        XCTAssertEqual(asked?.reference?.number, made.reference?.number)
    }

    func test_aMarkThatWasDeletedIsLetGoOfWhenTheFileChanges() throws {
        let (tool, f, viewer, made) = try editing()
        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))
        var raised = 0
        tool.selectionChanged = { raised += 1 }

        f.marker.delete(try XCTUnwrap(f.marker.find(0, try XCTUnwrap(made.reference?.number))))
        try f.tab.commit("Delete")
        tool.refresh()

        XCTAssertNil(tool.current)
        XCTAssertEqual(raised, 1)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_zoomingKeepsTheHandlesTheSameSizeOnScreen() throws {
        let (tool, _, viewer, _) = try editing()
        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))
        func gripSize() throws -> Double {
            let item = try XCTUnwrap(viewer.overlay(0).item(EditTool.selectionPrefix + "grip.0"))
            guard case .marker(_, let size, _) = item.shape else { return -1 }
            return size
        }
        let atFull = try gripSize()

        viewer.zoom = 2
        tool.redraw()

        XCTAssertEqual(try gripSize(), atFull)
    }

    func test_aMarkCannotBeDraggedOffThePage() throws {
        let (tool, _, viewer, _) = try editing()
        var moves: [(Double, Double)] = []
        tool.moved = { _, dx, dy in moves.append((dx, dy)) }

        tool.press(press(markPt(150, 130)))
        tool.move(drag(markPt(2000, -500)))
        tool.release(drag(markPt(2000, -500)))

        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].0, viewer.pageSize(0).width - 200, accuracy: 0.01)
        XCTAssertEqual(moves[0].1, -100, accuracy: 0.01)
    }

    func test_aMarkCannotBeResizedPastThePage() throws {
        let (tool, _, viewer, _) = try editing()
        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))
        var boxes: [ViewRect] = []
        tool.resized = { _, box in boxes.append(box) }

        tool.press(press(markPt(200, 160)))
        tool.move(drag(markPt(900, 1200)))
        tool.release(drag(markPt(900, 1200)))

        let size = viewer.pageSize(0)
        XCTAssertEqual(boxes, [ViewRect(100, 100, size.width - 100, size.height - 100)])
    }

    func test_aMarkTheFileLocksIsNotSelected() throws {
        let (tool, f, _, _) = try editing()
        f.marks()[0].dictionary["F"] = PdfNumber(AnnotationFlags([.print, .locked]).rawValue)

        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))

        XCTAssertNil(tool.current)
    }

    func test_aFingerIsTheToolsOnlyOverAMarkOrAHandle() throws {
        let (tool, _, _, _) = try editing()

        XCTAssertTrue(tool.takes(press(markPt(150, 130))))
        XCTAssertFalse(tool.takes(press(markPt(400, 400))))
        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))
        XCTAssertTrue(tool.takes(press(markPt(200, 160))))
    }

    func test_deleteAndEscapeAreTheToolsOnlyWhileAMarkIsSelected() throws {
        let (tool, _, viewer, _) = try editing()
        var deleted = 0
        tool.deleteRequested = { deleted += 1 }
        XCTAssertFalse(tool.key(.delete, modifiers: []))
        XCTAssertFalse(tool.key(.escape, modifiers: []))

        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))
        XCTAssertTrue(tool.key(.delete, modifiers: []))
        XCTAssertTrue(tool.key(.backspace, modifiers: []))
        XCTAssertEqual(deleted, 2)
        XCTAssertFalse(tool.key(.enter, modifiers: []))
        XCTAssertTrue(tool.key(.escape, modifiers: []))

        XCTAssertNil(tool.current)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }
}
