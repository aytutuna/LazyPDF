import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/measure/MeasureToolTests.cs: the pointer tool against a viewer that lays the page
// out, reads its words and answers its geometry. The Windows viewer is a proxy that answers only those three; this one is the
// real ViewerModel. Added: the live segment and the snap mark come only from a mouse that is not pressed, and a finger's
// press snaps and leaves no hover behind.

@MainActor
final class MeasureToolTests: XCTestCase {
    private let inches = MeasureScale(1, .inch, 1, .inch)

    private final class Done {
        var items: [MeasureItem] = []
    }

    private func start(_ kind: MeasureKind, withText: Bool = false) async throws -> (tool: MeasureTool, done: Done, viewer: ViewerModel) {
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text(2)), renderer: FakeRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(tab)
        let tool = MeasureTool(viewer: viewer)
        tool.kind = kind
        let done = Done()
        tool.finished = { done.items.append($0) }
        if withText {
            tool.preload([0])
            await waitUntil { tool.snaps[0] != nil }
        }
        return (tool, done, viewer)
    }

    private func at(_ x: Double, _ y: Double, clicks: Int = 1, page: Int = 0, modifiers: PointerModifiers = []) -> PagePointer {
        PagePointer(page: page, point: ViewPoint(x, y), view: ViewPoint(x * 2, y * 2), pressed: clicks > 0, clicks: clicks, modifiers: modifiers)
    }

    private func hover(_ x: Double, _ y: Double) -> PagePointer {
        PagePointer(page: 0, point: ViewPoint(x, y), view: ViewPoint(x * 2, y * 2), pressed: false, clicks: 0)
    }

    func test_twoClicksMakeADistance() async throws {
        let (tool, done, _) = try await start(.distance)

        tool.press(at(0, 0))
        XCTAssertTrue(done.items.isEmpty)
        tool.press(at(72, 0))

        XCTAssertEqual(done.items.count, 1)
        XCTAssertEqual(done.items[0].kind, .distance)
        XCTAssertEqual(done.items[0].value(inches), "1 in")
        XCTAssertTrue(tool.points.isEmpty)
    }

    func test_aDoubleClickEndsAnAreaWithoutAddingTheCornerTwice() async throws {
        let (tool, done, _) = try await start(.area)

        tool.press(at(0, 0))
        tool.press(at(72, 0))
        XCTAssertFalse(tool.canFinish)
        tool.press(at(72, 72))
        XCTAssertTrue(tool.canFinish)
        tool.press(at(72, 72, clicks: 2))

        XCTAssertEqual(done.items.count, 1)
        XCTAssertEqual(done.items[0].points.count, 3)
        XCTAssertEqual(done.items[0].value(inches).replacingOccurrences(of: ",", with: "."), "0.5 in²")
    }

    func test_clickingTheFirstCornerAgainClosesTheShape() async throws {
        let (tool, done, _) = try await start(.perimeter)

        tool.press(at(0, 0))
        tool.press(at(72, 0))
        tool.press(at(72, 72))
        tool.press(at(0, 72))
        tool.press(at(1, 1))

        XCTAssertEqual(done.items.count, 1)
        XCTAssertEqual(done.items[0].value(inches), "4 in")
    }

    func test_escapeDropsTheShapeAndAClickOnAnotherPageWaitsForIt() async throws {
        let (tool, done, _) = try await start(.area)

        tool.press(at(0, 0))
        tool.press(at(72, 0))
        tool.cancel()
        XCTAssertTrue(tool.points.isEmpty)

        tool.press(at(0, 0))
        tool.press(at(5, 5, page: 1))
        XCTAssertEqual(tool.page, 0)
        XCTAssertEqual(tool.points.count, 1)
        XCTAssertTrue(done.items.isEmpty)
    }

    func test_undoTakesBackTheLastCornerAndTheLastOneFreesThePage() async throws {
        let (tool, _, _) = try await start(.area)

        tool.press(at(0, 0))
        tool.press(at(72, 0))
        tool.undo()
        XCTAssertEqual(tool.points.count, 1)
        tool.undo()

        XCTAssertTrue(tool.points.isEmpty)
        XCTAssertEqual(tool.page, -1)
    }

    func test_aDoubleClickInADistanceDoesNotMakeAZeroLengthLine() async throws {
        let (tool, done, _) = try await start(.distance)

        tool.press(at(10, 10))
        tool.press(at(10, 10, clicks: 2))
        XCTAssertTrue(done.items.isEmpty)
        XCTAssertEqual(tool.points.count, 1)

        tool.press(at(82, 10))
        XCTAssertEqual(done.items.count, 1)
        XCTAssertEqual(done.items[0].value(inches), "1 in")
    }

    func test_shiftKeepsTheNextPointOnAStraightLine() async throws {
        let (tool, done, _) = try await start(.distance)

        tool.press(at(10, 10))
        tool.press(at(82, 13, modifiers: .shift))

        XCTAssertEqual(try XCTUnwrap(done.items.first).points[1].y, 10, accuracy: 1e-6)
    }

    func test_theStraightSwitchDoesWhatShiftDoesForAFinger() async throws {
        let (tool, done, _) = try await start(.distance)
        tool.straight = true

        tool.press(at(10, 10))
        tool.press(at(82, 13))

        XCTAssertEqual(try XCTUnwrap(done.items.first).points[1].y, 10, accuracy: 1e-6)
    }

    private func firstCorner(_ viewer: ViewerModel) async throws -> ViewPoint {
        let found = await viewer.text(0)
        let text = try XCTUnwrap(found)
        let word = try XCTUnwrap(text.words.first)
        let corner = viewer.geometry(0).toDisplay(word.bounds.left, word.bounds.top)
        return ViewPoint(corner.x, corner.y)
    }

    func test_clicksSnapToTheCornersOfWordsWhileSnappingIsOn() async throws {
        let (tool, done, viewer) = try await start(.distance, withText: true)
        let corner = try await firstCorner(viewer)

        tool.press(at(corner.x + 1, corner.y - 1))
        tool.press(at(300, 300))

        let start = try XCTUnwrap(done.items.first).points[0]
        XCTAssertEqual(start.x, corner.x, accuracy: 1e-6)
        XCTAssertEqual(start.y, corner.y, accuracy: 1e-6)
    }

    func test_withSnappingOffTheClickStaysWhereItWas() async throws {
        let (tool, done, viewer) = try await start(.distance, withText: true)
        tool.snap = false
        let corner = try await firstCorner(viewer)

        tool.press(at(corner.x + 1, corner.y - 1))
        tool.press(at(300, 300))

        XCTAssertEqual(try XCTUnwrap(done.items.first).points[0].x, corner.x + 1, accuracy: 1e-6)
    }

    func test_aMouseHoversWithALiveSegmentAndASnapMarkButAFingerLeavesNone() async throws {
        let (tool, _, viewer) = try await start(.area, withText: true)
        let corner = try await firstCorner(viewer)

        tool.press(at(0, 0))
        tool.press(at(300, 0))
        XCTAssertNil(tool.hover)
        XCTAssertFalse(tool.snapped)

        tool.move(hover(corner.x + 1, corner.y - 1))
        XCTAssertEqual(try XCTUnwrap(tool.hover).x, corner.x, accuracy: 1e-6)
        XCTAssertTrue(tool.snapped)
        XCTAssertEqual(tool.hoverPage, 0)

        tool.move(PagePointer(page: 0, point: ViewPoint(5, 5), view: ViewPoint(10, 10), pressed: true, clicks: 0))
        XCTAssertEqual(try XCTUnwrap(tool.hover).x, corner.x, accuracy: 1e-6)

        tool.cancel()
        XCTAssertNil(tool.hover)
        XCTAssertFalse(tool.snapped)
    }

    func test_escapeAndBackspaceAreTheToolsOnlyWhileAShapeIsUnderWay() async throws {
        let (tool, _, _) = try await start(.area)
        XCTAssertFalse(tool.key(.escape, modifiers: []))
        XCTAssertFalse(tool.key(.backspace, modifiers: []))

        tool.press(at(0, 0))
        tool.press(at(72, 0))
        XCTAssertTrue(tool.key(.backspace, modifiers: []))
        XCTAssertEqual(tool.points.count, 1)
        XCTAssertFalse(tool.key(.enter, modifiers: []))
        XCTAssertTrue(tool.key(.escape, modifiers: []))

        XCTAssertTrue(tool.points.isEmpty)
    }

    func test_theChangedCallbackTellsEveryStep() async throws {
        let (tool, _, _) = try await start(.perimeter)
        var told = 0
        tool.changed = { told += 1 }

        tool.press(at(0, 0))
        tool.press(at(72, 0))
        tool.press(at(72, 72))
        tool.finish()

        XCTAssertEqual(told, 4)
    }
}
