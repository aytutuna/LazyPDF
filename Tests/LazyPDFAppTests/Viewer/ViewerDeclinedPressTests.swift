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
