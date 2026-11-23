import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// A drag let go on the strip: a tab of another file takes the pages, the empty part makes a new tab, and the drag is over after each.
@MainActor
final class PageStripDropTests: XCTestCase {
    override func tearDown() async throws {
        PageDragSession.end()
    }

    private func pair() throws -> (a: PagesRig, b: PagesRig) {
        let a = try PagesRig(Pdfs.text(6, "From"), title: "a.pdf")
        let b = try PagesRig(Pdfs.text(3, "To"), title: "b.pdf")
        a.host.openDocuments = [a.tab, b.tab]
        return (a, b)
    }

    private func drag(_ rig: PagesRig, _ pages: [Int]) {
        PageDragSession.begin(PageDragPayload(tab: rig.tab, grid: nil, pages: pages))
    }

    func test_aTabOfAnotherFileTakesTheDraggedPagesAndTheDragIsOver() async throws {
        let (a, b) = try pair()
        let fromOrder = a.tab.order
        drag(a, [1, 2])

        XCTAssertTrue(PageTransfer.canDrop(onto: b.tab))
        await PageTransfer.drop(onto: b.tab, host: a.host)

        XCTAssertEqual(b.tab.pageCount, 5)
        XCTAssertEqual(b.tab.text(3), fromOrder[1])
        XCTAssertEqual(a.tab.order, fromOrder)
        XCTAssertNil(PageDragSession.current)
    }

    func test_theTabTheyAreInDoesNotTakeThem() async throws {
        let (a, _) = try pair()
        drag(a, [1])

        XCTAssertFalse(PageTransfer.canDrop(onto: a.tab))
        await PageTransfer.drop(onto: a.tab, host: a.host)

        XCTAssertEqual(a.tab.pageCount, 6)
        XCTAssertTrue(a.host.problems.isEmpty)
        XCTAssertNil(PageDragSession.current)
    }

    func test_theEmptyStripMakesANewTabOfThePages() async throws {
        let (a, _) = try pair()
        drag(a, [2, 3])

        XCTAssertTrue(PageTransfer.canDropOnStrip)
        await PageTransfer.dropOnStrip(host: a.host)

        let opened = try XCTUnwrap(a.host.openedNew.first)
        XCTAssertEqual(opened.title, "a extract.pdf")
        XCTAssertEqual(try PdfDocument.open(opened.pdf).pages.count, 2)
        XCTAssertNil(PageDragSession.current)
    }

    func test_withNoDragNothingIsAccepted() async throws {
        let (a, b) = try pair()

        XCTAssertFalse(PageTransfer.canDrop(onto: b.tab))
        XCTAssertFalse(PageTransfer.canDropOnStrip)
        await PageTransfer.drop(onto: b.tab, host: a.host)
        await PageTransfer.dropOnStrip(host: a.host)

        XCTAssertEqual(b.tab.pageCount, 3)
        XCTAssertTrue(a.host.openedNew.isEmpty)
    }

    func test_aDragWhoseTabWasClosedIsRefusedAtTheDrop() async throws {
        let (a, b) = try pair()
        drag(a, [0])
        a.tab.dispose()

        XCTAssertFalse(PageTransfer.canDrop(onto: b.tab))
        await PageTransfer.drop(onto: b.tab, host: a.host)

        XCTAssertEqual(b.tab.pageCount, 3)
    }
}
