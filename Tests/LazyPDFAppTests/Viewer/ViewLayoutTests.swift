import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/ViewLayoutTests.cs (PageLayoutTests there): where the pages sit, in one column or facing
// pages, with a cover, continuous or one spread at a time.

final class PageLayoutTests: XCTestCase {
    private let viewport = ViewSize(800, 600)

    private func pages(_ count: Int, width: Double = 100, height: Double = 200) -> [ViewSize] {
        Array(repeating: ViewSize(width, height), count: count)
    }

    private func options(columns: Int = 1, cover: Bool = false, continuous: Bool = true, rotation: Int = 0, scale: Double = 1, ppd: Double = 1) -> LayoutOptions {
        LayoutOptions(columns: columns, cover: cover, continuous: continuous, rotation: rotation, scale: scale, viewport: viewport, pixelsPerDip: ppd)
    }

    func test_pagesOfOneColumnAreStackedAndCentred() {
        let layout = ViewLayout.build(pages(3), options())

        let first = layout.pageRect(0)
        let second = layout.pageRect(1)
        XCTAssertEqual(first.size, ViewSize(100, 200))
        XCTAssertEqual(first.left, (800 - 100) / 2.0)
        XCTAssertEqual(first.top, ViewLayout.margin)
        XCTAssertEqual(second.top, first.bottom + ViewLayout.gap)
        XCTAssertEqual(layout.extent.height, ViewLayout.margin + 3 * 200 + 2 * ViewLayout.gap + ViewLayout.margin)
    }

    func test_noPagesLayOutNothingWhateverTheArrangement() {
        let layout = ViewLayout.build([], options(columns: 2, cover: true))

        XCTAssertEqual(layout.pageCount, 0)
    }

    func test_thePagesAreScaledByTheScale() {
        let layout = ViewLayout.build(pages(1), options(scale: 2.5))

        XCTAssertEqual(layout.pageRect(0).size, ViewSize(250, 500))
    }

    func test_aWidePageWidensTheScrolledAreaPastTheViewport() {
        let layout = ViewLayout.build(pages(1, width: 2000), options())

        XCTAssertEqual(layout.extent.width, 2000 + 2 * ViewLayout.margin)
        XCTAssertEqual(layout.pageRect(0).left, ViewLayout.margin)
    }

    func test_aSidewaysRotationLaysOutTheSwappedSize() {
        for rotation in [90, 270] {
            let layout = ViewLayout.build(pages(2), options(rotation: rotation))

            XCTAssertEqual(layout.pageRect(1).size, ViewSize(200, 100))
        }
    }

    func test_facingPagesSitSideBySide() {
        let layout = ViewLayout.build(pages(4), options(columns: 2))

        let (a, b, c) = (layout.pageRect(0), layout.pageRect(1), layout.pageRect(2))
        XCTAssertEqual(a.top, b.top)
        XCTAssertEqual(b.left, a.right + ViewLayout.gap)
        XCTAssertGreaterThan(c.top, a.bottom)
        XCTAssertEqual(a.left, c.left)
    }

    func test_aCoverStandsAloneOnTheRightAndTheNextTwoFace() {
        let layout = ViewLayout.build(pages(4), options(columns: 2, cover: true))

        let (cover, two, three, four) = (layout.pageRect(0), layout.pageRect(1), layout.pageRect(2), layout.pageRect(3))
        XCTAssertEqual(three.left, two.right + ViewLayout.gap)
        XCTAssertEqual(three.top, two.top)
        XCTAssertGreaterThan(two.top, cover.bottom)
        XCTAssertEqual(cover.left, three.left)
        XCTAssertEqual(four.left, two.left)
    }

    func test_aLastPageAloneKeepsTheLeftPlace() {
        let layout = ViewLayout.build(pages(3), options(columns: 2))

        XCTAssertEqual(layout.pageRect(2).left, layout.pageRect(0).left)
    }

    func test_theSpreadsAreCounted() {
        for (columns, cover, count, spreads) in [(1, false, 5, 5), (2, false, 5, 3), (2, true, 5, 3), (2, true, 4, 3), (2, false, 4, 2)] {
            XCTAssertEqual(ViewLayout.spreadsOf(columns, cover, count), spreads, "\(columns) \(cover) \(count)")
        }
    }

    func test_aSpreadHoldsItsPagesInOrder() {
        for (cover, spread, first, last) in [(true, 0, 0, 0), (true, 1, 1, 2), (true, 2, 3, 4), (false, 0, 0, 1), (false, 1, 2, 3)] {
            let (a, b) = ViewLayout.pagesOf(2, cover, spread, 6)

            XCTAssertEqual(a, first)
            XCTAssertEqual(b, last)
            XCTAssertEqual(ViewLayout.spreadOf(2, cover, first), spread)
        }
    }

    func test_aPagedLayoutHoldsOnlyTheSpreadAskedFor() {
        let layout = ViewLayout.build(pages(6), options(columns: 2, continuous: false), spread: 1)

        XCTAssertTrue(layout.contains(2))
        XCTAssertTrue(layout.contains(3))
        XCTAssertFalse(layout.contains(1))
        XCTAssertEqual(layout.firstSpread, 1)
        XCTAssertEqual(layout.lastSpread, 1)
        XCTAssertEqual(layout.extent.height, viewport.height)
        XCTAssertEqual(layout.pageRect(0), ViewRect.empty)
    }

    func test_aSpreadAskedForPastTheEndIsTheLast() {
        let layout = ViewLayout.build(pages(3), options(continuous: false), spread: 9)

        XCTAssertTrue(layout.contains(2))
    }

    func test_positionsAreWholeDevicePixels() {
        let layout = ViewLayout.build(pages(3, width: 101.3, height: 187.7), options(scale: 1.37, ppd: 1.25))

        for page in 0..<3 {
            let r = layout.pageRect(page)
            for v in [r.left, r.top, r.width, r.height] {
                XCTAssertEqual(v * 1.25, (v * 1.25).rounded(.toNearestOrEven), accuracy: 1e-6)
            }
        }
    }

    func test_thePagesInAnAreaAreTheOnesItMeets() {
        let layout = ViewLayout.build(pages(10), options())
        let second = layout.pageRect(1)

        XCTAssertEqual(layout.pagesIn(ViewRect(0, second.top + 10, 800, 20)), [1])
        XCTAssertEqual(layout.pagesIn(ViewRect(0, layout.pageRect(3).top + 150, 800, 150)), [3, 4])
    }

    func test_aPointOnAPageFindsItAndAPointInTheGapDoesNot() {
        let layout = ViewLayout.build(pages(3), options())
        let first = layout.pageRect(0)

        XCTAssertEqual(layout.pageAt(ViewPoint(first.left + 5, first.top + 5)), 0)
        XCTAssertEqual(layout.pageAt(ViewPoint(first.left + 5, first.bottom + ViewLayout.gap / 2)), -1)
        XCTAssertEqual(layout.pageAt(ViewPoint(1, 1)), -1)
    }

    func test_theNearestPageOfAPointInTheGapIsTheCloserOne() {
        let layout = ViewLayout.build(pages(3), options())
        let gap = layout.pageRect(0).bottom + 2

        XCTAssertEqual(layout.nearestPage(ViewPoint(400, gap)), 0)
        XCTAssertEqual(layout.nearestPage(ViewPoint(400, gap + 8)), 1)
        XCTAssertEqual(layout.nearestPage(ViewPoint(400, 100_000)), 2)
    }

    func test_thePageWithTheMostInViewIsTheCurrentOne() {
        let layout = ViewLayout.build(pages(5), options())
        let third = layout.pageRect(2)

        XCTAssertEqual(layout.mostVisible(ViewRect(0, third.top - 20, 800, 300)), 2)
        XCTAssertEqual(layout.mostVisible(ViewRect(0, layout.pageRect(1).top + 20, 800, 100)), 1)
        XCTAssertEqual(layout.mostVisible(ViewRect(0, 0, 800, 100)), 0)
    }

    func test_noPagesGiveAnEmptyLayout() {
        let layout = ViewLayout.build([], options())

        XCTAssertEqual(layout.pageCount, 0)
        XCTAssertTrue(layout.pagesIn(ViewRect(0, 0, 100, 100)).isEmpty)
        XCTAssertEqual(layout.pageAt(ViewPoint(1, 1)), -1)
    }
}
