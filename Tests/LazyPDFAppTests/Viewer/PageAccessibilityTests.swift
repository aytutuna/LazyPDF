import XCTest
import LazyPDFKit
@testable import LazyPDFApp

@MainActor
final class PageAccessibilityTests: XCTestCase {
    private final class Element {}

    private func open(pages: Int = 2) throws -> (viewer: ViewerModel, tab: DocumentTab) {
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text(pages)), renderer: FakeRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(tab)
        return (viewer, tab)
    }

    func test_theCacheGivesTheSameElementOnTheNextQuery() {
        var cache = PageElementCache<Element>()
        let first = cache.elements(for: [0, 1], epoch: 1) { _ in Element() }
        let again = cache.elements(for: [0, 1], epoch: 1) { _ in Element() }

        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first[0] === again[0] && first[1] === again[1])
        XCTAssertTrue(cache.element(for: 1) === first[1])
    }

    func test_theCacheStartsOverWhenTheEpochMoves() {
        var cache = PageElementCache<Element>()
        let first = cache.elements(for: [0], epoch: 1) { _ in Element() }

        let next = cache.elements(for: [0], epoch: 2) { _ in Element() }

        XCTAssertFalse(first[0] === next[0])
    }

    func test_aPageOutOfViewIsLetGoAndAPageWithoutAnElementIsSkipped() {
        var cache = PageElementCache<Element>()
        _ = cache.elements(for: [0, 1], epoch: 1) { _ in Element() }

        let found = cache.elements(for: [1, 2], epoch: 1) { $0 == 2 ? nil : Element() }

        XCTAssertEqual(found.count, 1)
        XCTAssertNil(cache.element(for: 0))
        XCTAssertNil(cache.element(for: 2))
    }

    func test_theEpochMovesWithAnotherFileAndWithANewRevision() async throws {
        let (viewer, tab) = try open()
        let shown = viewer.textEpoch

        viewer.show(try open().tab)
        let other = viewer.textEpoch
        XCTAssertGreaterThan(other, shown)

        viewer.show(tab)
        try TestPdfs.retitle(tab.session, "New title")
        let before = viewer.textEpoch
        XCTAssertTrue(try tab.commit("Properties"))
        for _ in 0..<300 where viewer.textEpoch == before { try await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertGreaterThan(viewer.textEpoch, before)
    }

    func test_thePageLoadedCallbackNamesThePage() async throws {
        let (viewer, _) = try open()
        var loaded: [Int] = []
        viewer.onPageLoaded = { loaded.append($0) }

        await viewer.loadPage(1)

        XCTAssertEqual(loaded, [1])
        XCTAssertNotNil(viewer.pageText(1))
    }
}

@MainActor
final class ViewerAccessibilityTests: XCTestCase {
    private func open(pages: Int = 2) async throws -> ViewerModel {
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text(pages)), renderer: FakeRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(tab)
        await viewer.loadPage(0)
        return viewer
    }

    func test_theMapIsKeptWhileThePageIsAndMadeAgainAfterAReset() async throws {
        let viewer = try await open()

        let first = try XCTUnwrap(viewer.textMap(0))

        XCTAssertTrue(viewer.textMap(0) === first)
        XCTAssertNil(viewer.textMap(1))
        viewer.resetText()
        XCTAssertNil(viewer.textMap(0))
    }

    func test_selectingARunSelectsThoseCharactersAndTellsTheListener() async throws {
        let viewer = try await open()
        var told = 0
        viewer.onSelectionChanged = { told += 1 }

        viewer.select(page: 0, LazyPDFKit.TextRange(2, 7))

        XCTAssertEqual(viewer.selectedChars(on: 0), LazyPDFKit.TextRange(2, 7))
        XCTAssertNil(viewer.selectedChars(on: 1))
        XCTAssertEqual(told, 1)
    }

    func test_aCaretSelectsNothingButIsStillAPlace() async throws {
        let viewer = try await open()

        viewer.select(page: 0, LazyPDFKit.TextRange(3, 3))

        XCTAssertFalse(viewer.hasSelection)
        XCTAssertNil(viewer.selectedChars(on: 0))
    }

    func test_aCharacterIsFoundWhereItIsShown() async throws {
        let viewer = try await open()
        let box = try XCTUnwrap(viewer.textBounds(page: 0, LazyPDFKit.TextRange(4, 5)))

        XCTAssertGreaterThan(box.width, 0)
        XCTAssertEqual(viewer.charIndex(page: 0, at: box.center), 4)
        XCTAssertNil(viewer.textBounds(page: 1, LazyPDFKit.TextRange(0, 1)))
        XCTAssertNil(viewer.charIndex(page: 1, at: box.center))
    }

    func test_theLinesInViewAreThoseThatShow() async throws {
        let viewer = try await open()

        XCTAssertEqual(viewer.visibleLines(on: 0), 0...0)
        viewer.scroll(by: 0, 100_000)
        XCTAssertNil(viewer.visibleLines(on: 0))
    }
}
