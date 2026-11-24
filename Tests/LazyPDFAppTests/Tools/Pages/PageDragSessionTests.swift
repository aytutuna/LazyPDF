import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The pages a drag carries live in PageDragSession, not in a grid: the grids of the Pages tool and the organize view are two
// objects over one tab, and a copy to another tab changes nothing in the source for either to notice.

@MainActor
final class PageDragSessionTests: XCTestCase {
    override func tearDown() async throws {
        PageDragSession.end()
    }

    private func grids(_ pages: Int = 6) throws -> (tool: PagesToolModel, organize: OrganizeModel, rig: PagesRig) {
        let rig = try PagesRig(Pdfs.text(pages))
        let tool = PagesToolModel()
        tool.attach(rig.tab, rig.viewer, rig.host)
        let organize = OrganizeModel()
        organize.attach(rig.tab, rig.viewer, rig.host)
        return (tool, organize, rig)
    }

    func test_aDragFromTheToolGridMovesPagesOnTheOrganizeGridOfTheSameTab() async throws {
        let (tool, organize, rig) = try grids()
        let was = rig.tab.order
        tool.grid.select([0, 1])

        tool.grid.beginDrag(1)
        XCTAssertTrue(organize.grid.acceptsDrag)
        organize.grid.mark(4, after: false)
        XCTAssertTrue(organize.grid.dropPages())

        XCTAssertEqual(rig.tab.order, [was[2], was[3], was[0], was[1], was[4], was[5]])
        XCTAssertNil(PageDragSession.current)
    }

    func test_aFinishedDragLeavesNothingForTheNextOneToMove() async throws {
        let (tool, organize, rig) = try grids()
        let was = rig.tab.order
        tool.grid.select([0, 1])
        tool.grid.beginDrag(0)
        tool.grid.mark(4, after: false)
        PageDragSession.end()

        XCTAssertFalse(tool.grid.acceptsDrag)
        XCTAssertFalse(tool.grid.dropPages())

        // The copy to another tab left no trace for the next drag to move.
        organize.grid.beginDrag(4)
        tool.grid.mark(0, after: false)
        XCTAssertTrue(tool.grid.dropPages())
        XCTAssertEqual(rig.tab.order, [was[4], was[0], was[1], was[2], was[3], was[5]])
    }

    func test_aNewDragReplacesTheOneBefore() async throws {
        let (tool, _, _) = try grids()

        tool.grid.beginDrag(1)
        tool.grid.beginDrag(3)

        XCTAssertEqual(PageDragSession.current?.pages, [3])
    }

    func test_theCellsBeingMadeAgainMidDragKeepTheDrag() async throws {
        let (tool, _, _) = try grids()
        tool.grid.beginDrag(2)

        tool.grid.rebuild(select: nil)

        XCTAssertEqual(PageDragSession.current?.pages, [2])
        XCTAssertTrue(tool.grid.acceptsDrag)
    }

    func test_aClosedTabTakesItsDragWithIt() async throws {
        let (tool, _, rig) = try grids()
        tool.grid.beginDrag(2)

        rig.tab.dispose()

        XCTAssertNil(PageDragSession.current)
        XCTAssertFalse(tool.grid.acceptsDrag)
    }

    func test_aDragOfAnotherTabIsIgnored() async throws {
        let (tool, _, rig) = try grids()
        let other = try PagesRig(Pdfs.text(4), title: "b.pdf")
        let was = rig.tab.order
        PageDragSession.begin(PageDragPayload(tab: other.tab, grid: nil, pages: [0]))
        tool.grid.mark(3, after: false)

        XCTAssertFalse(tool.grid.acceptsDrag)
        XCTAssertFalse(tool.grid.dropPages())
        XCTAssertEqual(rig.tab.order, was)
        XCTAssertEqual(other.tab.pageCount, 4)
        XCTAssertNil(PageDragSession.current)
    }
}
