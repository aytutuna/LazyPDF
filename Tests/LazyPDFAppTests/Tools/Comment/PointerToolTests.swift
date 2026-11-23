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

    private func finger(_ at: ViewPoint, page: Int = 0, pressed: Bool = true) -> PagePointer {
        PagePointer(page: page, point: at, view: at, pressed: pressed, clicks: pressed ? 1 : 0, touch: true)
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

    func test_aDragDrawsAPreviewAndGivesBothEndsOnRelease() async throws {
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

    func test_shiftStraightensALine() async throws {
        let (tool, _, drawn) = try drawing(.line)

        tool.press(press(markPt(10, 10)))
        tool.release(PagePointer(page: 0, point: markPt(100, 40), view: markPt(100, 40), pressed: true, clicks: 0, modifiers: [.shift]))

        XCTAssertEqual(drawn.marks[0].points[1].y, 10, accuracy: 0.001)
    }

    func test_aKeyedPressWithShiftHeldDoesNotSnapALineOrSquareABox() async throws {
        for kind in [MarkTool.line, .rectangle] {
            let (tool, _, drawn) = try drawing(kind)

            tool.press(press(markPt(10, 10)))
            tool.release(PagePointer(page: 0, point: markPt(100, 40), view: markPt(100, 40), pressed: false, clicks: 0, modifiers: [.shift], fromKeys: true))

            XCTAssertEqual(drawn.marks.count, 1)
            XCTAssertEqual(drawn.marks[0].points[1].x, 100, accuracy: 0.001)
            XCTAssertEqual(drawn.marks[0].points[1].y, 40, accuracy: 0.001)
        }
    }

    func test_shiftSquaresABoxInsideThePage() async throws {
        let (tool, _, drawn) = try drawing(.rectangle)

        tool.press(press(markPt(500, 700)))
        tool.release(PagePointer(page: 0, point: markPt(600, 710), view: markPt(600, 710), pressed: true, clicks: 0, modifiers: [.shift]))

        let end = drawn.marks[0].points[1]
        XCTAssertEqual(end.x, 600, accuracy: 0.001)
        XCTAssertEqual(end.y, 792, accuracy: 0.001)
    }

    func test_withoutShiftTheEndIsUnchanged() async throws {
        let (tool, _, drawn) = try drawing(.line)

        tool.press(press(markPt(10, 10)))
        tool.release(drag(markPt(100, 40)))

        XCTAssertEqual(drawn.marks[0].points[1], markPt(100, 40))
    }

    func test_aClickWithoutADragDrawsNothingForAShape() async throws {
        let (tool, viewer, drawn) = try drawing(.oval)

        tool.press(press(markPt(50, 60)))
        tool.release(drag(markPt(51, 60)))

        XCTAssertTrue(drawn.marks.isEmpty)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_aClickToolFinishesOnRelease() async throws {
        for kind in [MarkTool.note, .stamp, .attach] {
            let (tool, _, drawn) = try drawing(kind)

            tool.press(press(markPt(70, 80)))
            XCTAssertTrue(drawn.marks.isEmpty)
            tool.release(drag(markPt(70, 80)))

            XCTAssertEqual(drawn.marks.count, 1)
            XCTAssertEqual(drawn.marks[0].points, [markPt(70, 80)])
        }
    }

    func test_aClickWithTheTextBoxMakesABoxOfTheUsualSize() async throws {
        let (tool, _, drawn) = try drawing(.textBox)

        tool.press(press(markPt(70, 80)))
        tool.release(drag(markPt(70, 80)))

        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].points, [markPt(70, 80), markPt(230, 128)])
    }

    func test_aPolygonTakesOneCornerPerClickAndEndsOnADoubleClick() async throws {
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

    func test_aPolygonClosesWhenTheFirstCornerIsClickedAgain() async throws {
        let (tool, _, drawn) = try drawing(.cloud)
        for corner in [markPt(10, 10), markPt(100, 10), markPt(100, 100)] {
            tool.press(press(corner))
            tool.release(drag(corner))
        }

        tool.press(press(markPt(12, 11)))

        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].points.count, 3)
    }

    func test_aPolygonOfTwoCornersIsDropped() async throws {
        let (tool, viewer, drawn) = try drawing(.polygon)
        tool.press(press(markPt(10, 10)))
        tool.release(drag(markPt(10, 10)))
        tool.press(press(markPt(100, 10)))
        tool.release(drag(markPt(100, 10)))

        tool.press(press(markPt(100, 10), clicks: 2))

        XCTAssertTrue(drawn.marks.isEmpty)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_aPolygonWithCornersEnoughIsEndedByFinishShape() async throws {
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

    func test_freehandKeepsEveryPointOfTheDrag() async throws {
        let (tool, _, drawn) = try drawing(.pencil)

        tool.press(press(markPt(10, 10)))
        tool.move(drag(markPt(20, 14)))
        tool.move(drag(markPt(30, 22)))
        tool.release(drag(markPt(30, 22)))

        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].points, [markPt(10, 10), markPt(20, 14), markPt(30, 22)])
    }

    func test_aCalloutNeedsADragAndLeavesTwoPreviewShapes() async throws {
        let (tool, viewer, drawn) = try drawing(.callout)

        tool.press(press(markPt(100, 100)))
        tool.move(drag(markPt(300, 200)))
        XCTAssertEqual(viewer.overlay(0).items.count, 2)
        tool.release(drag(markPt(300, 200)))

        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].points, [markPt(100, 100), markPt(300, 200)])
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_cancellingDropsWhatWasStarted() async throws {
        let (tool, viewer, drawn) = try drawing(.line)
        tool.press(press(markPt(10, 10)))
        tool.move(drag(markPt(90, 90)))

        tool.cancel()
        tool.release(drag(markPt(90, 90)))

        XCTAssertTrue(drawn.marks.isEmpty)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_aDrawnPolygonKnowsItHasStartedUntilItIsCancelled() async throws {
        let (tool, viewer, _) = try drawing(.polygon)
        XCTAssertFalse(tool.started)

        tool.press(press(markPt(10, 10)))
        tool.release(drag(markPt(10, 10)))
        XCTAssertTrue(tool.started)

        tool.reset()
        XCTAssertFalse(tool.started)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_aFingersCornerIsAddedOnReleaseAndACancelledPressAddsNone() async throws {
        let (tool, _, drawn) = try drawing(.polygon)
        tool.press(press(markPt(10, 10)))
        tool.release(drag(markPt(10, 10)))
        tool.press(finger(markPt(100, 10)))
        tool.release(finger(markPt(100, 10), pressed: false))
        tool.press(finger(markPt(100, 100)))
        tool.release(finger(markPt(100, 100), pressed: false))
        XCTAssertTrue(tool.canFinish)

        tool.press(finger(markPt(50, 150)))
        tool.cancel()
        tool.release(finger(markPt(50, 150), pressed: false))
        tool.finishShape()

        XCTAssertEqual(drawn.marks.count, 1)
        XCTAssertEqual(drawn.marks[0].points.count, 3)
    }

    func test_aMousePressThatIsCancelledTakesBackOnlyItsCorner() async throws {
        let (tool, _, _) = try drawing(.polygon)
        tool.press(press(markPt(10, 10)))
        tool.release(drag(markPt(10, 10)))
        tool.press(press(markPt(100, 10)))
        tool.release(drag(markPt(100, 10)))
        tool.press(press(markPt(100, 100)))

        tool.cancel()

        XCTAssertTrue(tool.started)
        XCTAssertFalse(tool.canFinish)
        tool.press(press(markPt(10, 100)))
        tool.release(drag(markPt(10, 100)))
        XCTAssertTrue(tool.canFinish)
    }

    func test_aFirstCornerCancelledByASecondFingerLeavesNothingStarted() async throws {
        let (tool, viewer, _) = try drawing(.polygon)
        tool.press(finger(markPt(10, 10)))

        tool.cancel()

        XCTAssertFalse(tool.started)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_aPolygonWhosePageWasUndoneAwayCannotBeFinished() async throws {
        let (tool, viewer, drawn) = try drawing(.polygon, pages: 3)
        for corner in [markPt(10, 10), markPt(100, 10), markPt(100, 100)] {
            tool.press(press(corner, page: 2))
            tool.release(drag(corner, page: 2))
        }
        XCTAssertTrue(tool.canFinish)
        let tab = try XCTUnwrap(viewer.tab)
        try PageOperations.delete(tab.document, [2])
        try tab.commit("Delete pages")

        XCTAssertFalse(tool.canFinish)
        tool.finishShape()
        tool.press(press(markPt(20, 20), page: 0))

        XCTAssertTrue(drawn.marks.isEmpty)
        XCTAssertFalse(tool.canFinish)
    }

    func test_escapeDropsAShapeThatWasStartedAndIsLeftAloneOtherwise() async throws {
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

    func test_aPressOnAMarkSelectsItAndShowsAFrameWithEightHandles() async throws {
        let (tool, _, viewer, made) = try editing()
        var raised = 0
        tool.selectionChanged = { raised += 1 }

        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))

        XCTAssertEqual(tool.current?.reference?.number, made.reference?.number)
        XCTAssertEqual(viewer.overlay(0).items.count, 9)
        XCTAssertEqual(raised, 1)
    }

    func test_aMouseReachesFourPointsAndAFingerMore() async throws {
        let (tool, _, _, made) = try editing()

        tool.press(press(markPt(202, 130)))
        XCTAssertEqual(tool.current?.reference?.number, made.reference?.number)
        tool.press(press(markPt(400, 400)))

        tool.press(press(markPt(210, 130)))
        XCTAssertNil(tool.current)

        tool.press(finger(markPt(210, 130)))
        XCTAssertEqual(tool.current?.reference?.number, made.reference?.number)
    }

    func test_aHandleIsUnderAPointOnlyOnThePageOfTheSelectedMark() async throws {
        let (tool, _, _, _) = try editing(pages: 2)
        let corner = markPt(100, 100)

        XCTAssertFalse(tool.handleUnder(press(corner)))
        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))

        XCTAssertTrue(tool.handleUnder(press(corner)))
        XCTAssertFalse(tool.handleUnder(press(corner, page: 1)))
        XCTAssertFalse(tool.handleUnder(press(markPt(150, 130))))
    }

    func test_redrawingAfterTheMarksPageWentAwayDrawsNothing() async throws {
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

    func test_aPressOnNothingLetsGoOfTheSelection() async throws {
        let (tool, _, viewer, _) = try editing()
        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))

        tool.press(press(markPt(400, 400)))

        XCTAssertNil(tool.current)
        XCTAssertTrue(viewer.overlay(0).items.isEmpty)
    }

    func test_draggingAMarkAsksForTheMoveOnlyOnRelease() async throws {
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

    func test_aClickWithoutMovingAsksForNothing() async throws {
        let (tool, _, _, _) = try editing()
        var asked = 0
        tool.moved = { _, _, _ in asked += 1 }
        tool.resized = { _, _ in asked += 1 }

        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))

        XCTAssertEqual(asked, 0)
    }

    func test_draggingACornerHandleAsksForTheNewBox() async throws {
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

    func test_aMarkCannotBeResizedBelowASmallestSize() async throws {
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

    func test_aDoubleClickAsksToEditTheText() async throws {
        let (tool, _, _, made) = try editing()
        var asked: PdfAnnotation?
        tool.editRequested = { asked = $0 }

        tool.press(press(markPt(150, 130), clicks: 2))

        XCTAssertEqual(asked?.reference?.number, made.reference?.number)
    }

    func test_aMarkThatWasDeletedIsLetGoOfWhenTheFileChanges() async throws {
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

    func test_zoomingKeepsTheHandlesTheSameSizeOnScreen() async throws {
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

    func test_aMarkCannotBeDraggedOffThePage() async throws {
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

    func test_aMarkCannotBeResizedPastThePage() async throws {
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

    func test_aMarkTheFileLocksIsNotSelected() async throws {
        let (tool, f, _, _) = try editing()
        f.marks()[0].dictionary["F"] = PdfNumber(AnnotationFlags([.print, .locked]).rawValue)

        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))

        XCTAssertNil(tool.current)
    }

    func test_aSmallMarkKeepsMostOfItsAreaForMovingInsteadOfResizing() async throws {
        let f = try CommentFixture()
        let viewer = PanelViewer(f.tab)
        try f.marker.add(.note, 0, [markPt(100, 100)], markRed, "Look")
        try f.tab.commit("Note")
        let tool = EditTool(viewer: viewer, marker: { f.marker })
        var moves = 0
        var resizes = 0
        tool.moved = { _, _, _ in moves += 1 }
        tool.resized = { _, _ in resizes += 1 }

        tool.press(press(markPt(110, 110)))
        tool.move(drag(markPt(130, 110)))
        tool.release(drag(markPt(130, 110)))

        XCTAssertEqual(moves, 1)
        XCTAssertEqual(resizes, 0)
    }

    func test_aClickBetweenTwoMarksPicksTheOneUnderIt() async throws {
        let f = try CommentFixture()
        let viewer = PanelViewer(f.tab)
        let first = try f.marker.add(.textBox, 0, [markPt(100, 100), markPt(200, 140)], markRed, "First")
        let second = try f.marker.add(.textBox, 0, [markPt(100, 150), markPt(200, 190)], markRed, "Second")
        try f.tab.commit("Text boxes")
        let tool = EditTool(viewer: viewer, marker: { f.marker })

        tool.press(press(markPt(150, 135)))
        XCTAssertEqual(tool.current?.reference?.number, first.reference?.number)
        tool.release(drag(markPt(150, 135)))
        tool.press(press(markPt(150, 185)))

        XCTAssertEqual(tool.current?.reference?.number, second.reference?.number)
    }

    func test_aFingerNearAMarkStillPicksItWhenNothingLiesUnderIt() async throws {
        let (tool, _, _, made) = try editing()

        tool.press(finger(markPt(150, 175)))

        XCTAssertEqual(tool.current?.reference?.number, made.reference?.number)
    }

    func test_aFingerIsTheToolsOnlyOverAMarkOrAHandle() async throws {
        let (tool, _, _, _) = try editing()

        XCTAssertTrue(tool.takes(finger(markPt(150, 130))))
        XCTAssertFalse(tool.takes(finger(markPt(400, 400))))
        XCTAssertTrue(tool.takes(press(markPt(400, 400))))
        tool.press(press(markPt(150, 130)))
        tool.release(drag(markPt(150, 130)))
        XCTAssertTrue(tool.takes(finger(markPt(200, 160))))
    }

    func test_aMousePressOnEmptyPageThroughTheViewerLetsGoOfTheSelection() async throws {
        let (tool, f, _, _) = try editing()
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(f.tab)
        viewer.pointerTool = tool
        let matrix = try XCTUnwrap(viewer.pageToView(0))

        viewer.pointerDown(matrix.transform(markPt(150, 130)))
        viewer.pointerUp(matrix.transform(markPt(150, 130)))
        XCTAssertNotNil(tool.current)
        viewer.pointerDown(matrix.transform(markPt(20, 280)))
        viewer.pointerUp(matrix.transform(markPt(20, 280)))

        XCTAssertNil(tool.current)
    }

    func test_deleteAndEscapeAreTheToolsOnlyWhileAMarkIsSelected() async throws {
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

    // Corners and ends

    private func keyed(_ at: ViewPoint, pressed: Bool = true) -> PagePointer {
        PagePointer(page: 0, point: at, view: at, pressed: pressed, clicks: pressed ? 1 : 0, fromKeys: true)
    }

    private func shaped(_ tool: MarkTool, _ points: [ViewPoint]) throws -> (tool: EditTool, f: CommentFixture, viewer: PanelViewer, made: PdfAnnotation) {
        let f = try CommentFixture()
        let viewer = PanelViewer(f.tab)
        let made = try f.marker.add(tool, 0, points, markRed)
        try f.tab.commit("Shape")
        let edit = EditTool(viewer: viewer, marker: { f.marker })
        edit.select(f.marks()[0])
        return (edit, f, viewer, made)
    }

    private let square = [markPt(100, 100), markPt(300, 100), markPt(300, 300), markPt(100, 300)]

    func test_aSelectedLineHasRoundHandlesOnItsEndsInsteadOfEightBoxHandles() async throws {
        let (_, _, viewer, _) = try shaped(.line, [markPt(100, 100), markPt(300, 200)])

        XCTAssertEqual(viewer.overlay(0).items.count, 3)
        let item = try XCTUnwrap(viewer.overlay(0).item(EditTool.selectionPrefix + "grip.1"))
        guard case .marker(let center, _, let round) = item.shape else { return XCTFail("not a marker") }
        XCTAssertTrue(round)
        XCTAssertEqual(center.x, 300, accuracy: 0.5)
        XCTAssertNil(viewer.overlay(0).item(EditTool.selectionPrefix + "grip.2"))
    }

    func test_draggingAnEndAsksForTheNewPointOnRelease() async throws {
        let (tool, _, _, _) = try shaped(.line, [markPt(100, 100), markPt(300, 200)])
        var moves: [(Int, ViewPoint)] = []
        tool.vertexMoved = { _, index, to in moves.append((index, to)) }
        tool.moved = { _, _, _ in XCTFail("moved the mark") }

        tool.press(press(markPt(301, 201)))
        tool.move(drag(markPt(350, 260)))
        XCTAssertTrue(moves.isEmpty)
        tool.release(drag(markPt(350, 260)))

        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].0, 1)
        XCTAssertEqual(moves[0].1, markPt(349, 259))
    }

    func test_aPointIsKeptOnThePageWhileDragging() async throws {
        let (tool, _, viewer, _) = try shaped(.line, [markPt(100, 100), markPt(300, 200)])
        var to: ViewPoint?
        tool.vertexMoved = { _, _, point in to = point }

        tool.press(press(markPt(300, 200)))
        tool.move(drag(markPt(5000, -40)))
        tool.release(drag(markPt(5000, -40)))

        XCTAssertEqual(to, markPt(viewer.pageSize(0).width, 0))
    }

    func test_aClickOnACornerPicksItAndAnotherPressLetsGo() async throws {
        let (tool, _, _, _) = try shaped(.polygon, square)
        var picks: [Int] = []
        tool.vertexPicked = { picks.append($0) }
        tool.vertexMoved = { _, _, _ in XCTFail("moved") }

        tool.press(press(markPt(300, 300)))
        tool.release(drag(markPt(300, 300)))

        XCTAssertEqual(tool.pickedVertex, 2)
        XCTAssertEqual(picks, [2])
        tool.press(press(markPt(200, 200)))
        tool.release(drag(markPt(200, 200)))
        XCTAssertEqual(tool.pickedVertex, -1)
    }

    func test_aFingerAtTheEndOfAHorizontalLinePicksTheEndNotTheMark() async throws {
        let (tool, _, _, made) = try shaped(.line, [markPt(100, 100), markPt(300, 100)])
        var moves = 0
        tool.moved = { _, _, _ in moves += 1 }
        tool.vertexMoved = { _, _, _ in moves += 1 }

        let at = markPt(310, 104)
        XCTAssertTrue(tool.takes(finger(at)))
        tool.press(finger(at))
        tool.release(finger(at, pressed: false))

        XCTAssertEqual(tool.pickedVertex, 1)
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(tool.current?.reference?.number, made.reference?.number)
    }

    func test_aFingerThatDriftsALittleOnACornerStillPicksIt() async throws {
        let (tool, _, _, _) = try shaped(.line, [markPt(100, 100), markPt(300, 100)])
        var moves = 0
        tool.vertexMoved = { _, _, _ in moves += 1 }

        tool.press(finger(markPt(310, 104)))
        tool.move(finger(markPt(310.3, 104.2)))
        tool.release(finger(markPt(310.3, 104.2), pressed: false))

        XCTAssertEqual(tool.pickedVertex, 1)
        XCTAssertEqual(moves, 0)
    }

    func test_aDraggedCornerKeepsItsOffsetFromTheFinger() async throws {
        let (tool, _, _, _) = try shaped(.line, [markPt(100, 100), markPt(300, 100)])
        var to: ViewPoint?
        tool.vertexMoved = { _, _, point in to = point }

        tool.press(finger(markPt(310, 104)))
        tool.move(finger(markPt(330, 144)))
        tool.release(finger(markPt(330, 144), pressed: false))

        XCTAssertEqual(to, markPt(320, 140))
    }

    func test_aShortLineGivesAPressToTheNearerEndAndTheMiddleMovesIt() async throws {
        let (tool, _, _, _) = try shaped(.line, [markPt(100, 100), markPt(112, 100)])
        var picks: [Int] = []
        var moves = 0
        tool.vertexPicked = { picks.append($0) }
        tool.moved = { _, _, _ in moves += 1 }

        tool.press(press(markPt(102, 100)))
        tool.release(drag(markPt(102, 100)))
        XCTAssertEqual(picks, [0])
        tool.press(press(markPt(106, 102)))
        tool.move(drag(markPt(126, 140)))
        tool.release(drag(markPt(126, 140)))

        XCTAssertEqual(picks, [0])
        XCTAssertEqual(moves, 1)
    }

    func test_aPickSurvivesAChangeToTheLookButNotOneToThePointCount() async throws {
        let (tool, f, _, made) = try shaped(.polygon, square)
        tool.press(press(markPt(300, 300)))
        tool.release(drag(markPt(300, 300)))
        XCTAssertEqual(tool.pickedVertex, 2)

        _ = try f.marker.recolor(made, [0, 0, 1])
        try f.tab.commit("Change look")
        tool.refresh()
        XCTAssertEqual(tool.pickedVertex, 2)

        _ = try f.marker.removePoint(f.marks()[0], 0)
        try f.tab.commit("Remove point")
        tool.refresh()
        XCTAssertEqual(tool.pickedVertex, -1)
    }

    func test_aMeasuredOrForeignMarkShowsOnlyAFrameAndMovesFromItsCorners() async throws {
        for key in ["Measure", "LL"] {
            let (tool, f, viewer, _) = try shaped(.line, [markPt(100, 100), markPt(300, 200)])
            f.marks()[0].dictionary[key] = key == "LL" ? PdfNumber(1) : PdfDictionary()
            tool.refresh()
            var moved = 0
            tool.moved = { _, _, _ in moved += 1 }
            tool.resized = { _, _ in XCTFail("resized") }
            tool.vertexMoved = { _, _, _ in XCTFail("point moved") }

            XCTAssertEqual(viewer.overlay(0).items.count, 1)
            tool.press(press(markPt(300, 200)))
            tool.move(drag(markPt(320, 230)))
            tool.release(drag(markPt(320, 230)))

            XCTAssertEqual(moved, 1)
        }
    }

    func test_aStalePointAfterAnUndoLeavesNothingToMoveAndThrowsNothing() async throws {
        let (tool, f, _, made) = try shaped(.polygon, square)
        var moves = 0
        tool.vertexMoved = { _, _, _ in moves += 1 }

        tool.press(press(markPt(100, 300)))
        let fewer = try f.marker.removePoint(f.marks()[0], 3)
        XCTAssertEqual(fewer.vertices.count, 6)
        try f.tab.commit("Remove point")
        tool.refresh()
        tool.move(drag(markPt(90, 320)))
        tool.release(drag(markPt(90, 320)))

        XCTAssertEqual(moves, 0)
        XCTAssertEqual(tool.current?.reference?.number, made.reference?.number)
    }

    func test_enterOnACornerPicksItAndOpensTheCrossThere() async throws {
        let (tool, _, viewer, _) = try shaped(.polygon, square)
        var picks: [Int] = []
        tool.vertexPicked = { picks.append($0) }

        tool.press(keyed(markPt(300, 300)))
        tool.release(keyed(markPt(300, 300), pressed: false))

        XCTAssertEqual(tool.pickedVertex, 2)
        XCTAssertEqual(picks, [2])
        XCTAssertEqual(viewer.placements.count, 1)
        XCTAssertEqual(viewer.placements[0].point.x, 300, accuracy: 0.5)
        XCTAssertEqual(viewer.placements[0].point.y, 300, accuracy: 0.5)
    }

    func test_theSecondEnterMovesThePickedCornerAndLetsGoOfIt() async throws {
        let (tool, _, viewer, _) = try shaped(.polygon, square)
        var moves: [(Int, ViewPoint)] = []
        tool.vertexMoved = { _, index, to in moves.append((index, to)) }
        tool.press(keyed(markPt(300, 300)))
        tool.release(keyed(markPt(300, 300), pressed: false))

        tool.press(keyed(markPt(340, 320)))
        tool.release(keyed(markPt(340, 320), pressed: false))

        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].0, 2)
        XCTAssertEqual(moves[0].1, markPt(340, 320))
        XCTAssertEqual(tool.pickedVertex, -1)
        XCTAssertEqual(viewer.placementsCancelled, 0)
    }

    func test_escapeClosesTheCrossAndKeepsTheSelection() async throws {
        let (tool, _, viewer, _) = try shaped(.polygon, square)
        tool.press(keyed(markPt(300, 300)))

        XCTAssertTrue(tool.key(.escape, modifiers: []))

        XCTAssertEqual(tool.pickedVertex, -1)
        XCTAssertNotNil(tool.current)
        XCTAssertEqual(viewer.placementsCancelled, 1)
    }

    func test_anUndoThatMovesThePickedCornerLetsGoOfThePick() async throws {
        let (tool, f, viewer, _) = try shaped(.polygon, square)
        _ = try f.marker.movePoint(tool.current!, 2, markPt(340, 330))
        try f.tab.commit("Move point")
        tool.refresh()
        tool.press(keyed(markPt(340, 330)))
        XCTAssertEqual(tool.pickedVertex, 2)

        XCTAssertTrue(try f.tab.undo())
        tool.refresh()

        XCTAssertEqual(tool.pickedVertex, -1)
        XCTAssertEqual(viewer.placementsCancelled, 1)
    }

    func test_theViewerClosingTheCrossDropsThePick() async throws {
        let (tool, _, viewer, _) = try shaped(.polygon, square)
        tool.press(keyed(markPt(300, 300)))

        viewer.placementEnded?()

        XCTAssertEqual(tool.pickedVertex, -1)
        XCTAssertNotNil(tool.current)
        XCTAssertEqual(viewer.placementsCancelled, 0)
    }

    func test_deleteRemovesAPickedCornerAndOtherwiseTheMark() async throws {
        let (tool, _, viewer, _) = try shaped(.polygon, square)
        var removed: [Int] = []
        var deleted = 0
        tool.vertexRemoved = { _, index in removed.append(index) }
        tool.deleteRequested = { deleted += 1 }

        XCTAssertTrue(tool.key(.delete, modifiers: []))
        XCTAssertEqual(deleted, 1)
        tool.press(keyed(markPt(300, 300)))
        XCTAssertTrue(tool.key(.delete, modifiers: []))

        XCTAssertEqual(removed, [2])
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(tool.pickedVertex, -1)
        XCTAssertEqual(viewer.placementsCancelled, 1)
    }

    func test_enterOnASideAddsACornerThereButNotOnALine() async throws {
        let (tool, _, _, _) = try shaped(.polygon, square)
        var added: [(Int, ViewPoint)] = []
        tool.vertexAdded = { _, after, to in added.append((after, to)) }

        tool.press(keyed(markPt(200, 100)))

        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added[0].0, 0)
        XCTAssertEqual(added[0].1, markPt(200, 100))
        XCTAssertEqual(tool.pickedVertex, -1)

        let (lineTool, _, _, _) = try shaped(.line, [markPt(100, 100), markPt(300, 100)])
        lineTool.vertexAdded = { _, _, _ in XCTFail("added to a line") }
        lineTool.press(keyed(markPt(200, 100)))
    }

    private func held(_ at: ViewPoint, _ modifiers: PointerModifiers = [.shift], keys: Bool = false) -> PagePointer {
        PagePointer(page: 0, point: at, view: at, pressed: true, clicks: 0, modifiers: modifiers, fromKeys: keys)
    }

    func test_shiftStraightensAnEndOfALineAgainstTheOtherEndWhileItIsDragged() async throws {
        let (tool, _, _, _) = try shaped(.line, [markPt(100, 100), markPt(300, 200)])
        var moves: [(Int, ViewPoint)] = []
        tool.vertexMoved = { _, index, to in moves.append((index, to)) }

        tool.press(press(markPt(300, 200)))
        tool.move(held(markPt(340, 108)))
        tool.release(held(markPt(340, 108)))

        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].0, 1)
        XCTAssertEqual(moves[0].1.y, 100, accuracy: 1e-6)
        XCTAssertEqual(moves[0].1.x, 100 + hypot(240, 8), accuracy: 1e-6)
    }

    func test_shiftStraightensACornerAgainstThePreviousOneAndTheFirstAgainstTheLast() async throws {
        let (tool, _, _, _) = try shaped(.polygon, square)
        var moves: [(Int, ViewPoint)] = []
        tool.vertexMoved = { _, index, to in moves.append((index, to)) }

        tool.press(press(markPt(300, 300)))
        tool.move(held(markPt(306, 360)))
        tool.release(held(markPt(306, 360)))
        tool.press(press(markPt(100, 100)))
        tool.move(held(markPt(106, 40)))
        tool.release(held(markPt(106, 40)))

        XCTAssertEqual(moves.map(\.0), [2, 0])
        XCTAssertEqual(moves[0].1.x, 300, accuracy: 1e-6)
        XCTAssertEqual(moves[1].1.x, 100, accuracy: 1e-3)
    }

    func test_withoutShiftOrWithKeysAPointFollowsThePointerExactly() async throws {
        let (tool, _, _, _) = try shaped(.line, [markPt(100, 100), markPt(300, 200)])
        var moves: [ViewPoint] = []
        tool.vertexMoved = { _, _, to in moves.append(to) }

        tool.press(press(markPt(300, 200)))
        tool.move(held(markPt(340, 108), []))
        tool.release(held(markPt(340, 108), []))
        tool.press(press(markPt(340, 108)))
        tool.move(held(markPt(350, 118), [.shift], keys: true))
        tool.release(held(markPt(350, 118), [.shift], keys: true))

        XCTAssertEqual(moves, [markPt(340, 108), markPt(350, 118)])
    }

    func test_aPickFromTheMouseIsNotMovedByAnEnterElsewhere() async throws {
        let (tool, _, _, _) = try shaped(.polygon, square)
        tool.vertexMoved = { _, _, _ in XCTFail("moved") }
        tool.press(press(markPt(300, 300)))
        tool.release(drag(markPt(300, 300)))
        XCTAssertEqual(tool.pickedVertex, 2)

        tool.press(keyed(markPt(20, 20)))

        XCTAssertEqual(tool.pickedVertex, -1)
    }
}
