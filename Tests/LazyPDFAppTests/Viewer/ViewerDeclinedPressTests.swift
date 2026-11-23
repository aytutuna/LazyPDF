import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// A pointer tool that says it has no use for a press: the viewer goes on with its own mode, as the Windows viewer does where
// the controls of a tool are not under the pointer. Not in the Windows tests, which have no tool that declines.

@MainActor
private final class DecliningTool: PagePointerTool {
    var calls: [String] = []
    var cursor: PointerCursor? { nil }

    func takes(_ pointer: PagePointer) -> Bool { false }
    func press(_ pointer: PagePointer) { calls.append("press") }
    func move(_ pointer: PagePointer) { calls.append("move") }
    func release(_ pointer: PagePointer) { calls.append("release") }
    func cancel() { calls.append("cancel") }
}

@MainActor
final class ViewerDeclinedPressTests: XCTestCase {
    private func open() throws -> (viewer: ViewerModel, tab: DocumentTab) {
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text(3)), renderer: FakeRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(tab)
        return (viewer, tab)
    }

    func test_aPressTheToolDeclinesPansWhereTheHandIs() async throws {
        let (viewer, _) = try open()
        viewer.mode = .hand
        viewer.zoom = 1
        let tool = DecliningTool()
        viewer.pointerTool = tool

        viewer.pointerDown(ViewPoint(100, 300))
        viewer.pointerMove(ViewPoint(100, 250))
        viewer.pointerUp(ViewPoint(100, 250))

        XCTAssertEqual(viewer.offset.y, 50, accuracy: 1)
        XCTAssertFalse(tool.calls.contains("press"))
        XCTAssertFalse(tool.calls.contains("release"))
    }

    func test_aPressTheToolDeclinesSelectsWhereSelectIs() async throws {
        let (viewer, _) = try open()
        viewer.mode = .select
        let tool = DecliningTool()
        viewer.pointerTool = tool

        viewer.pointerDown(ViewPoint(100, 300), clicks: 2)
        viewer.pointerUp(ViewPoint(100, 300))

        XCTAssertFalse(tool.calls.contains("press"))
        XCTAssertFalse(tool.calls.contains("release"))
        XCTAssertTrue(viewer.pointerTool === tool)
    }
}

// A tool with one handle at a page point. It takes a press only on the handle, as the tools with handles do for a finger.
@MainActor
private final class HandleTool: PagePointerTool {
    let page: Int
    let at: ViewPoint
    var pressed: [PagePointer] = []
    var cursor: PointerCursor? { nil }

    init(page: Int, at: ViewPoint) {
        self.page = page
        self.at = at
    }

    func handleUnder(_ pointer: PagePointer) -> Bool {
        pointer.page == page && abs(pointer.point.x - at.x) <= 8 && abs(pointer.point.y - at.y) <= 8
    }

    func takes(_ pointer: PagePointer) -> Bool { handleUnder(pointer) }
    func press(_ pointer: PagePointer) { pressed.append(pointer) }
    func move(_ pointer: PagePointer) {}
    func release(_ pointer: PagePointer) {}
    func cancel() {}
}

@MainActor
final class ViewerHandlePressTests: XCTestCase {
    private func open() throws -> ViewerModel {
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text(3)), renderer: FakeRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(tab)
        viewer.zoom = 1
        return viewer
    }

    private func view(_ viewer: ViewerModel, _ page: Int, _ x: Double, _ y: Double) throws -> ViewPoint {
        try XCTUnwrap(viewer.pageToView(page)).transform(ViewPoint(x, y))
    }

    func test_aMousePressOnTheOuterHalfOfAnEdgeHandleReachesTheTool() async throws {
        let viewer = try open()
        let width = viewer.pageSize(0).width
        let tool = HandleTool(page: 0, at: ViewPoint(width, 100))
        viewer.pointerTool = tool

        viewer.pointerDown(try view(viewer, 0, width + 5, 100))
        viewer.pointerUp(try view(viewer, 0, width + 5, 100))

        let press = try XCTUnwrap(tool.pressed.first)
        XCTAssertEqual(press.page, 0)
        XCTAssertEqual(press.point.x, width + 5, accuracy: 0.01)
    }

    func test_aPressJustOffTheRightEdgeOfARotatedViewIsOffThePageOnThatSide() async throws {
        for rotation in [90, 270] {
            let viewer = try open()
            viewer.rotation = rotation
            let width = viewer.pageSize(0).width
            let tool = HandleTool(page: 0, at: ViewPoint(width, 100))
            viewer.pointerTool = tool

            viewer.pointerDown(try view(viewer, 0, width + 5, 100))
            viewer.pointerUp(try view(viewer, 0, width + 5, 100))

            let press = try XCTUnwrap(tool.pressed.first, "no press at \(rotation)")
            XCTAssertEqual(press.point.x, width + 5, accuracy: 0.01)
            XCTAssertEqual(press.point.y, 100, accuracy: 0.01)

            viewer.pointerDown(try view(viewer, 0, width + 20, 100))
            XCTAssertEqual(tool.pressed.count, 1, "gutter press at \(rotation)")
        }
    }

    func test_aPressInTheGutterBeyondTheHandleIsNotTheTools() async throws {
        let viewer = try open()
        let width = viewer.pageSize(0).width
        let tool = HandleTool(page: 0, at: ViewPoint(width, 100))
        viewer.pointerTool = tool

        viewer.pointerDown(try view(viewer, 0, width + 20, 100))
        viewer.pointerUp(try view(viewer, 0, width + 20, 100))
        viewer.pointerDown(try view(viewer, 0, width + 200, 100))
        viewer.pointerUp(try view(viewer, 0, width + 200, 100))

        XCTAssertTrue(tool.pressed.isEmpty)
    }

    func test_aPressPastTheMiddleOfTheGapStillBelongsToThePageWithTheHandle() async throws {
        let viewer = try open()
        let size = viewer.pageSize(0)
        let tool = HandleTool(page: 0, at: ViewPoint(size.width / 2, size.height))
        viewer.pointerTool = tool

        // The gap is 12 points, so 7 below the page is already nearer the next page.
        let at = try view(viewer, 0, size.width / 2, size.height + 7)
        XCTAssertEqual(viewer.state.hit(at, nearest: true)?.page, 1)
        viewer.pointerDown(at)
        viewer.pointerUp(at)

        let press = try XCTUnwrap(tool.pressed.first)
        XCTAssertEqual(press.page, 0)
        XCTAssertEqual(press.point.y, size.height + 7, accuracy: 0.01)
    }

    func test_aFingerOnTheOuterHalfOfAHandleIsTheToolsAndOneInTheGutterIsNot() async throws {
        let viewer = try open()
        let width = viewer.pageSize(0).width
        let tool = HandleTool(page: 0, at: ViewPoint(width, 100))
        viewer.pointerTool = tool

        XCTAssertTrue(viewer.toolTakes(try view(viewer, 0, width + 5, 100)))
        XCTAssertFalse(viewer.toolTakes(try view(viewer, 0, width + 20, 100)))

        viewer.pointerDown(try view(viewer, 0, width + 5, 100), touch: true)
        viewer.pointerUp(try view(viewer, 0, width + 5, 100))
        XCTAssertEqual(tool.pressed.count, 1)
    }

    func test_aToolWithoutHandlesGetsNoPressOffThePage() async throws {
        let viewer = try open()
        let width = viewer.pageSize(0).width
        let tool = DecliningTool()
        viewer.pointerTool = tool

        viewer.pointerDown(try view(viewer, 0, width + 5, 100), touch: true)
        viewer.pointerUp(try view(viewer, 0, width + 5, 100))

        XCTAssertFalse(viewer.toolTakes(try view(viewer, 0, width + 5, 100)))
        XCTAssertFalse(tool.calls.contains("press"))
    }
}
