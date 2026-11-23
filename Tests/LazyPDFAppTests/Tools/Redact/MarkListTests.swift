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

    func test_removingValuesKeepsTheOtherMarks() {
        let list = MarkList()
        let rect = RedactionMark.fromRect(0, PdfRect(400, 100, 420, 120))
        let hit = MarkItem(rect, "x", value: RedactionValueMatch(0, 2, .field, 5, 3, "abc", .word))
        list.add([hit, MarkItem(rect, "Box")])
        var changes = 0
        list.changed = { changes += 1 }

        XCTAssertTrue(list.removeValues())
        XCTAssertEqual(list.items.map(\.label), ["Box"])
        XCTAssertFalse(list.removeValues())
        XCTAssertEqual(changes, 1)
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

    private func box(_ page: Int, _ left: Double, _ bottom: Double, _ label: String = "box") -> MarkItem {
        MarkItem(RedactionMark.fromRect(page, PdfRect(left, bottom, left + 40, bottom + 10)), label, isBox: true)
    }

    func test_replacingAMarkKeepsTheCountSortsAndUndoesInOneStep() {
        let list = MarkList()
        let low = item(0, 10, 100, "low")
        let high = item(0, 10, 500, "high")
        list.add([low, high])
        var changes = 0
        list.changed = { changes += 1 }

        let moved = item(0, 10, 20, "moved")
        list.replace(high, moved)

        XCTAssertEqual(list.items.map(\.label), ["low", "moved"])
        XCTAssertEqual(changes, 1)
        XCTAssertNotEqual(moved.id, high.id)
        XCTAssertEqual(list.add([item(0, 10, 20.1)]), 0)
        XCTAssertTrue(list.canUndo)
        list.remove(list.items[1])
        list.undo()
        list.undo()

        XCTAssertEqual(list.items.map(\.label), ["high", "low"])
        XCTAssertEqual(list.add([item(0, 10, 500)]), 0)
        XCTAssertEqual(list.add([item(0, 10, 20)]), 1)
    }

    func test_undoBringsBackTheExactQuadsOfAReplacedBox() {
        let list = MarkList()
        let old = box(0, 10.123, 100.456)
        list.add([old])

        list.replace(old, box(0, 50, 60))
        list.undo()

        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.items[0].id, old.id)
        XCTAssertEqual(list.items[0].mark.quads[0].bounds.left, 10.123)
        XCTAssertEqual(list.items[0].mark.quads[0].bounds.bottom, 100.456)
    }

    func test_replacingAMissingItemDoesNothing() {
        let list = MarkList()
        list.add([item(0, 10, 100)])
        var changes = 0
        list.changed = { changes += 1 }

        list.replace(item(0, 10, 300), item(0, 20, 300))

        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(changes, 0)
        list.undo()
        XCTAssertTrue(list.items.isEmpty)
    }

    func test_replacingOntoAnExistingMarkKeepsBoth() {
        let list = MarkList()
        let fixed = item(0, 10, 100, "fixed")
        let moving = box(0, 10, 300)
        list.add([fixed, moving])

        list.replace(moving, box(0, 10, 100))

        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.add([item(0, 10, 100)]), 0)
        list.remove(list.items[0])
        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.add([item(0, 10, 100)]), 0)
    }

    func test_aReplacedBoxKeepsItsLabelAndFlag() {
        let list = MarkList()
        let old = box(0, 10, 100, "Box")
        list.add([old])

        list.replace(old, MarkItem(RedactionMark.fromRect(0, PdfRect(15, 100, 55, 110)), old.label, isBox: old.isBox))

        XCTAssertEqual(list.items[0].label, "Box")
        XCTAssertTrue(list.items[0].isBox)
    }

    func test_aRunOfCoalescingReplacesIsOneStep() {
        let list = MarkList()
        let first = box(0, 10, 100)
        list.add([first])
        let second = box(0, 11, 100)
        let third = box(0, 12, 100)
        let fourth = box(0, 13, 100)

        list.replace(first, second, coalesce: true)
        list.replace(second, third, coalesce: true)
        list.replace(third, fourth, coalesce: true)
        list.undo()

        XCTAssertEqual(list.items.map(\.id), [first.id])
        list.undo()
        XCTAssertTrue(list.items.isEmpty)
        XCTAssertFalse(list.canUndo)
    }

    func test_anyOtherChangeBreaksTheRun() {
        func run(_ interrupt: (MarkList, MarkItem) -> Void) -> Int {
            let list = MarkList()
            let first = box(0, 10, 100)
            list.add([first])
            let second = box(0, 11, 100)
            list.replace(first, second, coalesce: true)
            interrupt(list, second)
            let third = box(0, 12, 100)
            list.replace(list.items.first { $0.id == second.id } ?? second, third, coalesce: true)
            var steps = 0
            while list.canUndo {
                list.undo()
                steps += 1
            }
            return steps
        }

        XCTAssertEqual(run { _, _ in }, 2)
        XCTAssertEqual(run { list, _ in list.add([self.item(0, 10, 400)]) }, 4)
        XCTAssertEqual(run { list, _ in list.forget() }, 1)
    }

    func test_aReleaseThatIsNotCoalescedStartsANewStep() {
        let list = MarkList()
        let first = box(0, 10, 100)
        list.add([first])
        let second = box(0, 11, 100)
        let third = box(0, 12, 100)
        let fourth = box(0, 13, 100)
        list.replace(first, second, coalesce: true)
        list.replace(second, third)
        list.replace(third, fourth, coalesce: true)

        list.undo()
        XCTAssertEqual(list.items.map(\.id), [third.id])
        list.undo()
        XCTAssertEqual(list.items.map(\.id), [second.id])
        list.undo()
        XCTAssertEqual(list.items.map(\.id), [first.id])
    }

    func test_undoGoesBackThroughAddRemoveAndClear() {
        let list = MarkList()
        let one = item(0, 10, 100)
        let two = item(0, 10, 200)
        list.add([one])
        list.add([two])
        list.remove(one)
        list.clear()

        list.undo()
        XCTAssertEqual(list.items.map(\.id), [two.id])
        list.undo()
        XCTAssertEqual(list.items.count, 2)
        list.undo()
        list.undo()
        XCTAssertTrue(list.items.isEmpty)
        XCTAssertFalse(list.canUndo)
        XCTAssertEqual(list.add([one]), 1)
    }

    func test_historyKeepsTwentySteps() {
        let list = MarkList()
        for at in 0..<25 { list.add([item(0, Double(at) * 10, 100)]) }

        var steps = 0
        while list.canUndo {
            list.undo()
            steps += 1
        }

        XCTAssertEqual(steps, 20)
        XCTAssertEqual(list.items.count, 5)
    }

    func test_forgettingTheHistoryRaisesChangedOnlyWhenThereWasOne() {
        let list = MarkList()
        var changes = 0
        list.changed = { changes += 1 }

        list.forget()
        XCTAssertEqual(changes, 0)
        list.add([item(0, 10, 100)])
        list.forget()

        XCTAssertEqual(changes, 2)
        XCTAssertFalse(list.canUndo)
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
