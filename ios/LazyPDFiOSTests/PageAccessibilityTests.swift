import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

@MainActor
final class PageAccessibilityTests: XCTestCase {
    private func open(pages: Int = 3, line: String = "First line\nSecond line here") async throws -> (viewer: ViewerModel, scroll: PageScrollView) {
        let text = (0..<pages).map { "\(line) Page \($0 + 1)." }.joined(separator: "\u{0C}")
        let bytes = try PdfFromText.create(text).bytes
        let tab = DocumentTab(session: try PdfEditSession.open(bytes), renderer: StubRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { StubRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(400, 800), pixelsPerDip: 1)
        viewer.show(tab)
        viewer.zoom = 0.5
        let scroll = PageScrollView(viewer: viewer)
        scroll.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        scroll.layoutIfNeeded()
        for page in 0..<pages { await viewer.loadPage(page) }
        return (viewer, scroll)
    }

    private func elements(_ scroll: PageScrollView) -> [PageReadingElement] {
        (scroll.accessibilityElements ?? []).compactMap { $0 as? PageReadingElement }
    }

    func test_aQueryFindsTheSameElementsAsTheOneBeforeAndNewOnesAfterAReset() async throws {
        let (viewer, scroll) = try await open()

        let first = elements(scroll)
        let second = elements(scroll)

        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(zip(first, second).allSatisfy { $0 === $1 })
        viewer.resetText()
        XCTAssertFalse(elements(scroll).first === first.first)
    }

    func test_aPageIsReadLineByLine() async throws {
        let (_, scroll) = try await open()
        let page = try XCTUnwrap(elements(scroll).first)

        XCTAssertEqual(page.accessibilityLabel, "Page 1 of 3")
        XCTAssertEqual(page.accessibilityContent(forLineNumber: 0), "First line")
        XCTAssertEqual(page.accessibilityContent(forLineNumber: 1), "Second line here Page 1.")
        XCTAssertNil(page.accessibilityContent(forLineNumber: 2))
        XCTAssertNil(page.accessibilityContent(forLineNumber: -1))
        XCTAssertEqual(page.accessibilityPageContent(), "First line\nSecond line here Page 1.")
        XCTAssertEqual(page.accessibilityValue, page.accessibilityPageContent())
    }

    func test_aLineHasAPlaceOnTheScreen() async throws {
        let (_, scroll) = try await open()
        let page = try XCTUnwrap(elements(scroll).first)

        XCTAssertGreaterThan(page.accessibilityFrame(forLineNumber: 0).width, 0)
        XCTAssertEqual(page.accessibilityFrame(forLineNumber: 9), .zero)
    }

    func test_onlyTheLastPageInViewAsksForAPageTurn() async throws {
        let (_, scroll) = try await open()

        let pages = elements(scroll)

        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertTrue(pages.last?.accessibilityTraits.contains(.causesPageTurn) == true)
        XCTAssertTrue(pages.dropLast().allSatisfy { !$0.accessibilityTraits.contains(.causesPageTurn) })
    }

    func test_scrollingNextTurnsToTheNextPageAndPreviousGoesBack() async throws {
        let (viewer, scroll) = try await open()
        let page = try XCTUnwrap(elements(scroll).first)

        XCTAssertTrue(page.accessibilityScroll(.next))
        XCTAssertEqual(viewer.pageIndex, 1)
        let second = try XCTUnwrap(elements(scroll).first { $0.page == 1 })
        XCTAssertTrue(second.accessibilityScroll(.previous))
        XCTAssertEqual(viewer.pageIndex, 0)
        XCTAssertFalse(page.accessibilityScroll(.previous))
        XCTAssertFalse(page.accessibilityScroll(.left))
    }

    func test_thereIsNoPageAfterTheLastToTurnTo() async throws {
        let (viewer, scroll) = try await open(pages: 1)
        let page = try XCTUnwrap(elements(scroll).first)

        XCTAssertFalse(page.accessibilityScroll(.next))
        XCTAssertEqual(viewer.pageIndex, 0)
    }
}
