import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors the parts of windows/LazyPDF.App.Tests/KeyboardPlacementTests.cs that drive the page viewer: a tool that places
// something by clicking can be driven from the keyboard. The tests that put the signature, crop and redact tools on the
// viewer belong to those tools and are not ported here; the mouse click that makes no box is the redact tool's too. The rest
// checks what PageViewer does that the surface alone does not: the bar's state on the tab, the history, links, the pointer.

// The viewer belongs to the main actor; a poll that ran on another thread would read its cache while tiles are filed in it.
@MainActor
private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<300 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), file: file, line: line)
}

@MainActor
private final class RecordingTool: PagePointerTool {
    var calls: [(kind: String, pointer: PagePointer)] = []
    var cancelled = false
    var cursor: PointerCursor? { nil }

    func press(_ pointer: PagePointer) { calls.append(("press", pointer)) }
    func move(_ pointer: PagePointer) { calls.append(("move", pointer)) }
    func release(_ pointer: PagePointer) { calls.append(("release", pointer)) }
    func cancel() { cancelled = true }
}

private struct WeakTab {
    weak var tab: DocumentTab?
    init(_ tab: DocumentTab) { self.tab = tab }
}

@MainActor
final class ViewerModelTests: XCTestCase {
    private var opened: [URL] = []

    private func open(pages: Int = 2, bytes: [UInt8]? = nil) throws -> (viewer: ViewerModel, tab: DocumentTab) {
        let tab = DocumentTab(session: try PdfEditSession.open(bytes ?? Pdfs.text(pages)), renderer: FakeRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { [unowned self] in opened.append($0) })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(tab)
        return (viewer, tab)
    }

    func test_enterThenEnterClicksInTheMiddleOfThePageInView() throws {
        let (viewer, _) = try open()
        let tool = RecordingTool()
        viewer.pointerTool = tool
        let size = viewer.pageSize(0)

        XCTAssertTrue(viewer.placeWithKeys(.enter))
        XCTAssertTrue(tool.calls.isEmpty)
        XCTAssertNotNil(viewer.placement)
        XCTAssertTrue(viewer.placeWithKeys(.enter))

        XCTAssertEqual(tool.calls.map(\.kind), ["press", "release"])
        let click = tool.calls[0].pointer
        XCTAssertEqual(click.page, 0)
        XCTAssertTrue((0...size.width).contains(click.point.x))
        XCTAssertTrue((0...size.height).contains(click.point.y))
        XCTAssertEqual(click.point, tool.calls[1].pointer.point)
        XCTAssertTrue(click.fromKeys)
        XCTAssertNil(viewer.placement)
    }

    func test_theArrowKeysMoveTheClick() throws {
        let (viewer, _) = try open()
        let tool = RecordingTool()
        viewer.pointerTool = tool
        viewer.placeWithKeys(.enter)
        viewer.placeWithKeys(.enter)
        let middle = tool.calls[0].pointer.point
        tool.calls.removeAll()

        viewer.placeWithKeys(.enter)
        viewer.placeWithKeys(.right)
        viewer.placeWithKeys(.right)
        viewer.placeWithKeys(.down)
        viewer.placeWithKeys(.enter)

        let moved = tool.calls[0].pointer.point
        XCTAssertGreaterThan(moved.x, middle.x)
        XCTAssertGreaterThan(moved.y, middle.y)
    }

    func test_escapeLetsGoWithoutAClick() throws {
        let (viewer, _) = try open()
        let tool = RecordingTool()
        viewer.pointerTool = tool
        viewer.placeWithKeys(.enter)

        XCTAssertTrue(viewer.placeWithKeys(.escape))

        XCTAssertTrue(tool.calls.isEmpty)
        XCTAssertFalse(viewer.placeWithKeys(.right))
    }

    func test_withoutAToolTheKeysAreTheViewers() throws {
        let (viewer, _) = try open()
        viewer.pointerTool = RecordingTool()
        viewer.pointerTool = nil

        XCTAssertFalse(viewer.placeWithKeys(.enter))
    }

    func test_theTabKeepsThePageTheZoomAndTheFit() throws {
        let (viewer, tab) = try open(pages: 3)

        XCTAssertEqual(tab.fit, .width)
        XCTAssertEqual(tab.zoom, 0)
        viewer.zoom = 2
        XCTAssertEqual(tab.fit, FitMode.none)
        XCTAssertEqual(tab.zoom, 2)
        viewer.fit = .page
        XCTAssertEqual(tab.fit, .page)
        XCTAssertEqual(tab.zoom, 0)
        viewer.goToPage(2)
        XCTAssertEqual(tab.pageIndex, 2)
        XCTAssertEqual(viewer.pageIndex, 2)
    }

    func test_aTabComesBackAsItWasLeft() throws {
        let (viewer, first) = try open(pages: 3)
        viewer.zoom = 1.5
        viewer.goToPage(2)
        let second = DocumentTab(session: try PdfEditSession.open(Pdfs.text(2)), renderer: FakeRenderer(), url: nil, title: "b.pdf")

        viewer.show(second)
        viewer.show(first)

        XCTAssertEqual(viewer.pageIndex, 2)
        XCTAssertEqual(viewer.zoom, 1.5, accuracy: 1e-9)
    }

    func test_showingNothingEmptiesTheViewer() throws {
        let (viewer, _) = try open()

        viewer.show(nil)

        XCTAssertEqual(viewer.pageCount, 0)
        XCTAssertNil(viewer.tab)
        XCTAssertTrue(viewer.visiblePages.isEmpty)
    }

    func test_aPageIsLabelledByTheFileElseByItsNumber() throws {
        let (viewer, _) = try open(pages: 2)

        XCTAssertEqual(viewer.pageLabel(1), "2")
    }

    func test_readingModeFitsTheWidthAndGivesTheArrangementBack() throws {
        let (viewer, _) = try open(pages: 3)
        viewer.columns = 2
        viewer.continuous = false
        viewer.zoom = 1.25

        viewer.readingMode = true
        XCTAssertEqual(viewer.columns, 1)
        XCTAssertTrue(viewer.continuous)
        XCTAssertEqual(viewer.fit, .width)
        viewer.readingMode = false

        XCTAssertEqual(viewer.columns, 2)
        XCTAssertFalse(viewer.continuous)
        XCTAssertEqual(viewer.zoom, 1.25, accuracy: 1e-9)
    }

    func test_aPinchZoomsAboutThePointAndTheZoomStepsKeepToTheUsualOnes() throws {
        let (viewer, _) = try open()
        viewer.zoom = 1

        viewer.magnify(by: 1.5, about: ViewPoint(400, 300))
        XCTAssertEqual(viewer.zoom, 1.5, accuracy: 1e-9)
        XCTAssertEqual(viewer.fit, FitMode.none)
        viewer.zoomIn()
        XCTAssertEqual(viewer.zoom, 2, accuracy: 1e-9)
        viewer.actualSize()
        XCTAssertEqual(viewer.zoom, 1, accuracy: 1e-9)
        viewer.magnify(by: -3, about: .zero)
        XCTAssertEqual(viewer.zoom, 1, accuracy: 1e-9)
    }

    func test_aDoubleTapFitsTheWidthAndThenComesIn() throws {
        let (viewer, _) = try open()
        viewer.zoom = 0.5

        viewer.toggleZoom(about: ViewPoint(100, 100))
        XCTAssertEqual(viewer.fit, .width)
        let fitted = viewer.zoom
        viewer.toggleZoom(about: ViewPoint(100, 100))

        XCTAssertEqual(viewer.zoom, fitted * 2, accuracy: 1e-9)
    }

    func test_theViewRevisionMovesWithTheScroll() throws {
        let (viewer, _) = try open(pages: 3)
        viewer.zoom = 2
        let before = viewer.viewRevision

        viewer.scroll(by: 0, 120)

        XCTAssertGreaterThan(viewer.viewRevision, before)
        XCTAssertEqual(viewer.offset.y, 120)
    }

    func test_aJumpIsInTheHistoryAndScrollingIsNot() throws {
        let (viewer, _) = try open(pages: 3)
        XCTAssertFalse(viewer.canGoBack)

        viewer.goToPage(2)
        XCTAssertTrue(viewer.canGoBack)
        viewer.goBack()
        XCTAssertEqual(viewer.pageIndex, 0)
        XCTAssertTrue(viewer.canGoForward)
        viewer.goForward()

        XCTAssertEqual(viewer.pageIndex, 2)
    }

    func test_aDestinationAndTheNamedActionsMoveThePage() throws {
        let (viewer, _) = try open(pages: 3)

        viewer.follow(GoToAction(PdfDestination(1)))
        XCTAssertEqual(viewer.pageIndex, 1)
        viewer.follow(NamedAction("LastPage"))
        XCTAssertEqual(viewer.pageIndex, 2)
        viewer.follow(NamedAction("FirstPage"))
        XCTAssertEqual(viewer.pageIndex, 0)
        viewer.follow(NamedAction("NextPage"))
        XCTAssertEqual(viewer.pageIndex, 1)
        viewer.follow(NamedAction("GoBack"))
        XCTAssertEqual(viewer.pageIndex, 0)
        viewer.follow(NamedAction("Find"))
        XCTAssertTrue(viewer.findVisible)
    }

    func test_anAddressIsOpenedOnlyAfterTheQuestionIsAnswered() throws {
        let (viewer, _) = try open()

        viewer.follow(UriAction("https://example.com/a"))
        XCTAssertEqual(viewer.pendingAddress, PendingAddress(address: "https://example.com/a", openable: true))
        XCTAssertTrue(opened.isEmpty)
        viewer.openPendingAddress()

        XCTAssertEqual(opened, [URL(string: "https://example.com/a")!])
        XCTAssertNil(viewer.pendingAddress)
    }

    func test_anAddressOfAnotherKindIsShownButNeverOpened() throws {
        let (viewer, _) = try open()

        viewer.follow(UriAction("file:///etc/passwd"))
        XCTAssertEqual(viewer.pendingAddress?.openable, false)
        viewer.openPendingAddress()
        viewer.follow(UriAction("not an address"))
        viewer.openPendingAddress()
        viewer.follow(UriAction("https://example.com"))
        viewer.dismissPendingAddress()
        viewer.openPendingAddress()

        XCTAssertTrue(opened.isEmpty)
    }

    func test_thePageBoxTakesANumberAndRefusesWhatIsNotAPage() throws {
        let (viewer, _) = try open(pages: 3)

        XCTAssertTrue(viewer.goToPage(typed: " 3 "))
        XCTAssertEqual(viewer.pageIndex, 2)
        XCTAssertFalse(viewer.goToPage(typed: "4"))
        XCTAssertFalse(viewer.goToPage(typed: "0"))
        XCTAssertFalse(viewer.goToPage(typed: "x"))
        XCTAssertEqual(viewer.pageIndex, 2)
    }

    func test_pagesStepBySpreadWhenFacingPagesShow() throws {
        let (viewer, _) = try open(pages: 5)
        viewer.columns = 2
        viewer.coverPage = true

        viewer.stepPage(1)
        XCTAssertEqual(viewer.pageIndex, 1)
        viewer.stepPage(1)
        XCTAssertEqual(viewer.pageIndex, 3)
        viewer.stepPage(-1)
        XCTAssertEqual(viewer.pageIndex, 1)
    }

    func test_handModeDragsThePageAlong() throws {
        let (viewer, _) = try open(pages: 3)
        viewer.mode = .hand
        viewer.zoom = 1

        viewer.pointerDown(ViewPoint(100, 300))
        viewer.pointerMove(ViewPoint(100, 250))
        viewer.pointerUp(ViewPoint(100, 250))

        XCTAssertEqual(viewer.offset.y, 50, accuracy: 1)
    }

    func test_aPointerToolGetsThePressTheMovesAndTheRelease() throws {
        let (viewer, _) = try open()
        let tool = RecordingTool()
        viewer.pointerTool = tool
        let at = try XCTUnwrap(viewer.pageToView(0)).transform(ViewPoint(50, 50))

        viewer.pointerDown(at, clicks: 1, modifiers: .shift)
        viewer.pointerMove(ViewPoint(at.x + 10, at.y + 10))
        viewer.pointerUp(ViewPoint(at.x + 20, at.y + 20))

        // After the release the pointer is hovering again, which the tool is told too.
        XCTAssertEqual(tool.calls.map(\.kind), ["press", "move", "release", "move"])
        XCTAssertEqual(tool.calls[0].pointer.point.x, 50, accuracy: 1e-6)
        XCTAssertEqual(tool.calls[2].pointer.point.y, 50 + 20 / (viewer.zoom * PageSpace.dipPerPoint), accuracy: 1e-6)
        XCTAssertTrue(tool.calls[0].pointer.modifiers.contains(.shift))
        XCTAssertTrue(tool.calls[0].pointer.pressed)
        XCTAssertFalse(tool.calls[2].pointer.pressed)
    }

    func test_escapeDuringAToolPressCancelsIt() throws {
        let (viewer, _) = try open()
        let tool = RecordingTool()
        viewer.pointerTool = tool
        let at = try XCTUnwrap(viewer.pageToView(0)).transform(ViewPoint(50, 50))
        viewer.pointerDown(at)

        viewer.key(.escape)

        XCTAssertTrue(tool.cancelled)
    }

    func test_escapeClosesTheFindBar() throws {
        let (viewer, _) = try open()
        viewer.showFind()

        viewer.key(.escape)

        XCTAssertFalse(viewer.findVisible)
    }

    func test_settingAnotherToolCancelsTheOneBefore() throws {
        let (viewer, _) = try open()
        let first = RecordingTool()
        viewer.pointerTool = first

        viewer.pointerTool = RecordingTool()
        XCTAssertTrue(first.cancelled)
        viewer.mode = .hand

        XCTAssertNil(viewer.pointerTool)
    }

    func test_theKeysScrollAndTurnPages() throws {
        let (viewer, _) = try open(pages: 3)
        viewer.zoom = 1

        viewer.key(.down)
        XCTAssertEqual(viewer.offset.y, PageSurfaceState.lineStep)
        viewer.key(.pageDown)
        XCTAssertGreaterThan(viewer.offset.y, PageSurfaceState.lineStep)
        viewer.key(.end)
        XCTAssertEqual(viewer.pageIndex, 2)
        viewer.key(.home)
        XCTAssertEqual(viewer.pageIndex, 0)
        XCTAssertFalse(viewer.key(.enter))
    }

    private func pointOnFirstLine(_ viewer: ViewerModel, _ char: Int) async throws -> ViewPoint {
        let loaded = await viewer.text(0)
        let text = try XCTUnwrap(loaded)
        await waitFor { viewer.pageText(0) != nil }
        let center = text.chars[char].quad.center
        let shown = viewer.geometry(0).toDisplay(center.x, center.y)
        return try XCTUnwrap(viewer.pageToView(0)).transform(ViewPoint(shown.x, shown.y))
    }

    func test_aDoubleClickSelectsAWordAndCopyGivesIt() async throws {
        let (viewer, _) = try open()
        let at = try await pointOnFirstLine(viewer, 1)

        viewer.pointerDown(at, clicks: 2)
        viewer.pointerUp(at)

        XCTAssertTrue(viewer.hasSelection)
        let copied = await viewer.selectedText()
        XCTAssertEqual(copied, "Hello")
        viewer.key(.escape)
        XCTAssertFalse(viewer.hasSelection)
    }

    func test_aTripleClickSelectsTheLine() async throws {
        let (viewer, _) = try open()
        let at = try await pointOnFirstLine(viewer, 1)

        viewer.pointerDown(at, clicks: 3)
        viewer.pointerUp(at)

        let copied = await viewer.selectedText()
        XCTAssertEqual(copied?.hasPrefix("Hello from the tests."), true)
    }

    func test_draggingSelectsFromThePressToThePointer() async throws {
        let (viewer, _) = try open()
        let from = try await pointOnFirstLine(viewer, 0)
        let to = try await pointOnFirstLine(viewer, 10)

        viewer.pointerDown(from)
        viewer.pointerMove(ViewPoint(to.x + 1, to.y))
        viewer.pointerUp(ViewPoint(to.x + 1, to.y))

        let copied = await viewer.selectedText()
        XCTAssertEqual(copied?.hasPrefix("Hello from"), true)
        XCTAssertFalse(viewer.highlights(of: 0).selection.isEmpty)
    }

    func test_selectAllReachesEveryPage() async throws {
        let (viewer, _) = try open(pages: 3)

        viewer.selectAll()

        let runs = await viewer.selection()
        XCTAssertEqual(runs.map(\.page), [0, 1, 2])
        XCTAssertTrue(runs[2].text.contains("Page 3."))
    }

    func test_aMatchHasItsShapeOnItsPage() async throws {
        let (viewer, _) = try open(pages: 2)

        await viewer.search.start("tests", TextSearchOptions()).value

        XCTAssertEqual(viewer.search.hits.count, 2)
        XCTAssertFalse(viewer.highlights(of: 0).currentHit.isEmpty)
        XCTAssertTrue(viewer.highlights(of: 0).hits.isEmpty)
        XCTAssertFalse(viewer.highlights(of: 1).hits.isEmpty)
        viewer.search.next()
        XCTAssertFalse(viewer.highlights(of: 0).hits.isEmpty)
    }

    func test_findSeedsItselfFromAWordSelectedOnOnePage() async throws {
        let (viewer, _) = try open()
        let at = try await pointOnFirstLine(viewer, 1)
        viewer.pointerDown(at, clicks: 2)
        viewer.pointerUp(at)

        viewer.showFind()

        XCTAssertTrue(viewer.findVisible)
        XCTAssertEqual(viewer.findSeed, "Hello")
        viewer.hideFind()
        XCTAssertFalse(viewer.findVisible)
    }

    func test_thePagesInViewGetTheirPictures() async throws {
        let (viewer, _) = try open(pages: 2)

        await waitFor { viewer.tilesPending == 0 && !viewer.drawing(of: 0).pictures.isEmpty }

        let drawing = viewer.drawing(of: 0)
        XCTAssertFalse(drawing.failed)
        XCTAssertFalse(drawing.pictures.isEmpty)
        let area = ViewRect(0, 0, 800, 600)
        XCTAssertTrue(drawing.pictures.allSatisfy { $0.rect.intersectsWith(area) })
    }

    func test_aPageThatCannotBeDrawnIsSaidSo() async throws {
        let renderer = FakeRenderer()
        renderer.draws = false
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text(1)), renderer: renderer, url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)

        viewer.show(tab)

        XCTAssertTrue(viewer.cannotDraw)
        XCTAssertTrue(viewer.drawing(of: 0).pictures.isEmpty)
    }

    func test_aCommitDrawsTheNewStateAndKeepsThePlace() async throws {
        let (viewer, tab) = try open(pages: 3)
        viewer.goToPage(1)
        try TestPdfs.retitle(tab.session, "New title")

        XCTAssertTrue(try tab.commit("Properties"))
        await waitFor { viewer.seenRevision == tab.revision }

        XCTAssertEqual(viewer.pageIndex, 1)
        XCTAssertEqual(viewer.pageCount, 3)
    }

    func test_aLayerSwitchedOffIsOffInTheViewAndNotInTheFile() async throws {
        let (viewer, tab) = try open(bytes: TestPdfs.layered())
        XCTAssertEqual(viewer.layers.layers.map(\.isOn), [true, true])

        viewer.setLayerVisible(TestPdfs.blackBox, false)
        await waitFor { viewer.layers.layers.first?.isOn == false }

        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(PdfLayers.read(tab.document).layers.map(\.isOn), [true, true])
        viewer.setLayerVisible(TestPdfs.blackBox, true)
        await waitFor { viewer.layers.layers.first?.isOn == true }
    }

    func test_aTabThatWasShownAndLeftIsNotKeptAlive() throws {
        let (viewer, _) = try open()
        func showAndLeave() throws -> WeakTab {
            let other = DocumentTab(session: try PdfEditSession.open(Pdfs.text(1)), renderer: FakeRenderer(), url: nil, title: "b.pdf")
            viewer.show(other)
            viewer.show(nil)
            return WeakTab(other)
        }
        let gone = try showAndLeave()
        XCTAssertNil(gone.tab)
    }

    func test_pagesDeletedBeforeTheReloadDoNotBreakTheLookups() throws {
        let (viewer, tab) = try open(pages: 10)
        try PageOperations.delete(tab.document, [4, 5, 6, 7, 8, 9])
        XCTAssertTrue(try tab.commit("Delete pages"))

        _ = viewer.geometry(9)
        XCTAssertNil(viewer.link(at: 9, ViewPoint(10, 10)))
    }
}
