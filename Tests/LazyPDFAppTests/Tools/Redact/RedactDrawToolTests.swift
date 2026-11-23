import XCTest
@testable import LazyPDFApp

// The arithmetic of editing a drawn box, ported from windows/LazyPDF.App.Tests/Tools/redact/RedactBoxEditorTests.cs.

final class RedactDrawToolTests: XCTestCase {
    private typealias Handle = RedactDrawTool.Handle
    private static let page = ViewSize(200, 100)
    private static let box = ViewRect(50, 40, 60, 30)

    private func drag(_ rect: ViewRect, _ handle: Handle, _ dx: Double, _ dy: Double, page: ViewSize = page) -> ViewRect {
        RedactDrawTool.drag(rect, handle, ViewPoint(dx, dy), page)
    }

    func test_eachHandleMovesItsOwnEdges() {
        let cases: [(Handle, ViewRect)] = [
            (.body, ViewRect(60, 45, 60, 30)), (.topLeft, ViewRect(60, 45, 50, 25)), (.top, ViewRect(50, 45, 60, 25)),
            (.topRight, ViewRect(50, 45, 70, 25)), (.right, ViewRect(50, 40, 70, 30)), (.bottomRight, ViewRect(50, 40, 70, 35)),
            (.bottom, ViewRect(50, 40, 60, 35)), (.bottomLeft, ViewRect(60, 40, 50, 35)), (.left, ViewRect(60, 40, 50, 30)),
        ]
        XCTAssertEqual(cases.count, Handle.allCases.count)
        for (handle, expected) in cases {
            XCTAssertEqual(drag(Self.box, handle, 10, 5), expected, "\(handle)")
        }
    }

    func test_movingStopsAtThePageEdges() {
        XCTAssertEqual(drag(Self.box, .body, -500, -500), ViewRect(0, 0, 60, 30))
        XCTAssertEqual(drag(Self.box, .body, 500, 500), ViewRect(140, 70, 60, 30))
    }

    func test_resizingStopsAtThePageEdges() {
        XCTAssertEqual(drag(Self.box, .topLeft, -500, -500), ViewRect(0, 0, 110, 70))
        XCTAssertEqual(drag(Self.box, .bottomRight, 500, 500), ViewRect(50, 40, 150, 60))
    }

    func test_resizingKeepsTheMinimumAndDoesNotFlip() {
        XCTAssertEqual(drag(Self.box, .left, 500, 0), ViewRect(106, 40, 4, 30))
        XCTAssertEqual(drag(Self.box, .bottom, 0, -500), ViewRect(50, 40, 60, 4))
    }

    func test_aMinimumBoxAGrainShortOfThePageEdgeCanStillBeDragged() {
        let page = ViewSize(595.276, 841.89)
        let grain = 3.9999999999999996
        let right = ViewRect(page.width - grain, 100, grain, 30)
        let bottom = ViewRect(100, page.height - grain, 30, grain)

        let wider = drag(right, .right, -10, 0, page: page)
        let taller = drag(bottom, .bottom, 0, -10, page: page)

        XCTAssertTrue(wider.width >= 3.99 && wider.right <= page.width + 1e-9)
        XCTAssertTrue(taller.height >= 3.99 && taller.bottom <= page.height + 1e-9)
        XCTAssertTrue(drag(right, .left, 10, 0, page: page).width >= 3.99)
        XCTAssertTrue(drag(bottom, .top, 0, 10, page: page).height >= 3.99)
    }

    func test_arrowKeysStepByOneOrTen() {
        func nudge(_ arrow: RedactDrawTool.Arrow, resize: Bool = false, large: Bool = false) -> ViewRect {
            RedactDrawTool.nudge(Self.box, arrow, resize: resize, large: large, Self.page)
        }
        XCTAssertEqual(nudge(.left), ViewRect(49, 40, 60, 30))
        XCTAssertEqual(nudge(.right), ViewRect(51, 40, 60, 30))
        XCTAssertEqual(nudge(.up, large: true), ViewRect(50, 30, 60, 30))
        XCTAssertEqual(nudge(.down, large: true), ViewRect(50, 50, 60, 30))
        XCTAssertEqual(nudge(.right, resize: true), ViewRect(50, 40, 61, 30))
        XCTAssertEqual(nudge(.left, resize: true), ViewRect(50, 40, 59, 30))
        XCTAssertEqual(nudge(.down, resize: true, large: true), ViewRect(50, 40, 60, 40))
        XCTAssertEqual(nudge(.up, resize: true, large: true), ViewRect(50, 40, 60, 20))
    }

    func test_keyStepsStopAtAllFourEdges() {
        func nudge(_ rect: ViewRect, _ arrow: RedactDrawTool.Arrow) -> ViewRect {
            RedactDrawTool.nudge(rect, arrow, resize: false, large: true, Self.page)
        }
        XCTAssertEqual(nudge(ViewRect(4, 40, 60, 30), .left), ViewRect(0, 40, 60, 30))
        XCTAssertEqual(nudge(ViewRect(135, 40, 60, 30), .right), ViewRect(140, 40, 60, 30))
        XCTAssertEqual(nudge(ViewRect(50, 4, 60, 30), .up), ViewRect(50, 0, 60, 30))
        XCTAssertEqual(nudge(ViewRect(50, 65, 60, 30), .down), ViewRect(50, 70, 60, 30))
    }

    func test_keyResizingStopsAtThePageAndTheMinimum() {
        func grow(_ rect: ViewRect, _ arrow: RedactDrawTool.Arrow) -> ViewRect {
            RedactDrawTool.nudge(rect, arrow, resize: true, large: true, Self.page)
        }
        XCTAssertEqual(grow(ViewRect(50, 40, 145, 30), .right), ViewRect(50, 40, 150, 30))
        XCTAssertEqual(grow(ViewRect(50, 40, 60, 55), .down), ViewRect(50, 40, 60, 60))
        XCTAssertEqual(grow(ViewRect(50, 40, 8, 30), .left), ViewRect(50, 40, 4, 30))
        XCTAssertEqual(grow(ViewRect(50, 40, 60, 8), .up), ViewRect(50, 40, 60, 4))
    }
}
