import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/redact/MarkListTests.cs: the marks of the Redact tool before anything is removed, the
// list, and the move between page space and the file's. The Windows file's "AMarkTakenOutCanBeAddedAgain" is kept as it is; an
// item keeps its identity here, so a mark taken out is the same item when it comes back.

final class MarkListTests: XCTestCase {
    private func item(_ page: Int, _ left: Double, _ bottom: Double, _ label: String = "x") -> MarkItem {
        MarkItem(RedactionMark.fromRect(page, PdfRect(left, bottom, left + 40, bottom + 10)), label)
    }

    func test_twoHitsInOneCommentAreTwoMarks() {
        let list = MarkList()
        let rect = RedactionMark.fromRect(0, PdfRect(400, 100, 420, 120))
        func hit(_ start: Int) -> MarkItem {
            MarkItem(rect, "x", value: RedactionValueMatch(0, 2, .comment, start, 3, "abc", .word))
        }

        XCTAssertEqual(list.add([hit(0), hit(10)]), 2)
        XCTAssertEqual(list.add([hit(10)]), 0)
        XCTAssertEqual(list.add([MarkItem(rect, "Box")]), 1)
    }

    func test_marksComeInReadingOrder() {
        let list = MarkList()

        list.add([item(1, 10, 100, "late"), item(0, 10, 100, "low"), item(0, 10, 500, "high"), item(0, 80, 500, "right")])

        XCTAssertEqual(list.items.map(\.label), ["high", "right", "low", "late"])
    }

    func test_aMarkOnTheSamePlaceIsNotAddedTwice() {
        let list = MarkList()
        var changes = 0
        list.changed = { changes += 1 }

        XCTAssertEqual(list.add([item(0, 10, 100)]), 1)
        XCTAssertEqual(list.add([item(0, 10.2, 100.1)]), 0)
        XCTAssertEqual(list.add([item(1, 10, 100), item(1, 10, 100)]), 1)

        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(changes, 2)
    }

    func test_aBoxFarBeyondAnyPageDoesNotOverflow() {
        let list = MarkList()

        XCTAssertEqual(list.add([item(0, 1e30, 1e30, "far"), item(0, -1e30, -1e30, "back")]), 2)
        XCTAssertEqual(list.add([item(0, 1e30, 1e30, "far")]), 0)

        list.remove(list.items[0])
        XCTAssertEqual(list.items.count, 1)
    }

    func test_removingAndClearingTellTheListeners() {
        let list = MarkList()
        let first = item(0, 10, 100)
        list.add([first, item(0, 10, 200)])
        var changes = 0
        list.changed = { changes += 1 }

        list.remove(first)
        list.remove(first)
        list.clear()
        list.clear()

        XCTAssertTrue(list.items.isEmpty)
        XCTAssertEqual(changes, 2)
    }

    func test_aBoxDraggedOnAPageComesBackWhereItWasDrawn() {
        for rotate in [0, 90, 180, 270] {
            let geometry = PageGeometry(PdfRect(0, 0, 200, 300), rotate)

            let mark = MarkShapes.box(2, geometry, from: ViewPoint(60, 45), to: ViewPoint(10, 20))
            let outline = MarkShapes.outline(geometry, mark.quads[0])

            XCTAssertEqual(mark.page, 2)
            XCTAssertEqual(outline.count, 4)
            XCTAssertEqual(outline.map(\.x).min()!, 10, accuracy: 1e-6, "\(rotate)")
            XCTAssertEqual(outline.map(\.x).max()!, 60, accuracy: 1e-6, "\(rotate)")
            XCTAssertEqual(outline.map(\.y).min()!, 20, accuracy: 1e-6, "\(rotate)")
            XCTAssertEqual(outline.map(\.y).max()!, 45, accuracy: 1e-6, "\(rotate)")
        }
    }

    func test_aBoxReadsLeftToRightAsItIsShownOnATurnedPage() {
        for rotate in [0, 90, 180, 270] {
            let geometry = PageGeometry(PdfRect(0, 0, 200, 300), rotate)

            let quad = MarkShapes.box(0, geometry, from: ViewPoint(10, 20), to: ViewPoint(200, 40)).quads[0]

            let a = geometry.toDisplay(quad.x0, quad.y0)
            let b = geometry.toDisplay(quad.x1, quad.y1)
            let d = geometry.toDisplay(quad.x3, quad.y3)
            XCTAssertEqual(b.x - a.x, 190, accuracy: 1e-6, "\(rotate)")
            XCTAssertEqual(b.y - a.y, 0, accuracy: 1e-6, "\(rotate)")
            XCTAssertEqual(d.x - a.x, 0, accuracy: 1e-6, "\(rotate)")
            XCTAssertEqual(d.y - a.y, -20, accuracy: 1e-6, "\(rotate)")
        }
    }

    func test_markingThousandsOfPlacesAtOnceIsQuick() {
        let list = MarkList()
        let items = (0..<40_000).map { item($0 % 40, Double($0 / 40 % 20 * 45), Double($0 / 800 * 12)) }
        let start = Date()

        let added = list.add(items)

        XCTAssertEqual(added, 40_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func test_aMarkTakenOutCanBeAddedAgain() {
        let list = MarkList()
        let one = item(0, 10, 100)
        list.add([one])
        list.remove(one)

        XCTAssertEqual(list.add([one]), 1)
        list.clear()
        XCTAssertEqual(list.add([one]), 1)
    }

    func test_aBoxIsInUserSpaceWithTheOriginAtTheBottom() {
        let geometry = PageGeometry(PdfRect(0, 0, 200, 300), 0)

        let bounds = MarkShapes.box(0, geometry, from: ViewPoint(10, 20), to: ViewPoint(60, 45)).quads[0].bounds

        XCTAssertEqual([bounds.left, bounds.bottom, bounds.right, bounds.top], [10, 255, 60, 280])
    }

    func test_pagesAreWrittenAsRanges() {
        XCTAssertEqual(RedactSummary.pageRanges([]), "")
        XCTAssertEqual(RedactSummary.pageRanges([0]), "1")
        XCTAssertEqual(RedactSummary.pageRanges([6, 1, 2, 3]), "2-4, 7")
        XCTAssertEqual(RedactSummary.pageRanges([0, 2, 4]), "1, 3, 5")
    }
}
