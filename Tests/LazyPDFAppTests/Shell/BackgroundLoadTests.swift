import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The renderer of a big file loads off the main actor after an edit; the tab says so through `drawn` only when the load
// is for the latest edit and the tab is still open.

private final class GatedRenderer: DocumentRenderer {
    var loadsInBackground: Bool { true }
    var started = 0
    var closed = false
    private var gates: [CheckedContinuation<Bool, Never>] = []

    func load(_ session: PdfEditSession, _ password: String?) -> Bool { true }
    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (200, 300) }
    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { nil }
    func close() { closed = true }

    @MainActor
    func loadAsync(_ session: PdfEditSession, _ password: String?) async -> Bool {
        started += 1
        return await withCheckedContinuation { gates.append($0) }
    }

    @MainActor
    func finish(_ result: Bool = true) {
        gates.removeFirst().resume(returning: result)
    }

    var waiting: Int { gates.count }
}

@MainActor
final class BackgroundLoadTests: XCTestCase {
    private func open() throws -> (DocumentTab, GatedRenderer) {
        let renderer = GatedRenderer()
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text()), renderer: renderer, url: nil, title: "a.pdf")
        return (tab, renderer)
    }

    func test_aCommitReturnsBeforeTheLoadFinishes() async throws {
        let (tab, renderer) = try open()
        try Pdfs.retitle(tab.session, "One")

        XCTAssertTrue(try tab.commit("Properties"))
        await settle { renderer.waiting == 1 }

        XCTAssertEqual(tab.revision, 1)
        XCTAssertEqual(tab.drawn, 0)
        renderer.finish(false)
        await settle { tab.drawn == 1 }
        XCTAssertFalse(tab.canDraw)
    }

    func test_onlyTheLoadOfTheLatestEditIsReported() async throws {
        let (tab, renderer) = try open()
        try Pdfs.retitle(tab.session, "One")
        try tab.commit("One")
        await settle { renderer.waiting == 1 }
        try Pdfs.retitle(tab.session, "Two")
        try tab.commit("Two")

        renderer.finish()
        await settle { renderer.started == 2 }
        XCTAssertEqual(tab.drawn, 0)
        renderer.finish()
        await settle { tab.drawn == 1 }
        await Task.yield()

        XCTAssertEqual(tab.drawn, 1)
    }

    func test_aLoadForAClosedTabIsDropped() async throws {
        let (tab, renderer) = try open()
        try Pdfs.retitle(tab.session, "One")
        try tab.commit("One")
        await settle { renderer.waiting == 1 }

        tab.dispose()
        renderer.finish()
        await settle { renderer.closed }
        await Task.yield()

        XCTAssertEqual(tab.drawn, 0)
    }

    func test_aRendererThatLoadsInPlaceReportsAtOnce() async throws {
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text()), renderer: FakeRenderer(), url: nil, title: "a.pdf")
        try Pdfs.retitle(tab.session, "One")
        try tab.commit("One")

        XCTAssertEqual(tab.drawn, 1)
    }
}
