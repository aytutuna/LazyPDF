import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors the parts of windows/LazyPDF.App.Tests/KeyboardPlacementTests.cs that drive the page viewer: a tool that places
// something by clicking can be driven from the keyboard. The tests that put the signature, crop and redact tools on the
// viewer belong to those tools and are not ported here; the mouse click that makes no box is the redact tool's too. The rest
// checks what PageViewer does that the surface alone does not: the bar's state on the tab, the history, links, the pointer.

// The viewer belongs to the main actor; a poll that ran on another thread would read its cache while tiles are filed in it.
@MainActor
private func waitFor(_ condition: () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath,
                     line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(30)
    while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), message(), file: file, line: line)
}

private final class HalfRenderer: TileRenderer {
    var previews = true
    var tiles = true

    func load(_ session: PdfEditSession, _ password: String?) -> Bool { true }
    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (200, 300) }
    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { previews ? PdfRgbaImage(4, 6, [UInt8](repeating: 255, count: 96)) : nil }
    func renderTile(_ pageIndex: Int, _ pixelsPerPoint: Double, _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> PdfRgbaImage? {
        tiles ? PdfRgbaImage(width, height, [UInt8](repeating: 255, count: width * height * 4)) : nil
    }
    func close() {}
}

@MainActor
private final class RecordingTool: PagePointerTool {
    var calls: [(kind: String, pointer: PagePointer)] = []
    var cancelled = false
    var takesAll = true
    var usedKeys: [ViewerKey] = []
    var keysTaken: Set<ViewerKey> = []
    var cursor: PointerCursor? { nil }

    func takes(_ pointer: PagePointer) -> Bool { takesAll }

    func key(_ key: ViewerKey, modifiers: PointerModifiers) -> Bool {
        usedKeys.append(key)
        return keysTaken.contains(key)
    }

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

    func test_enterThenEnterClicksInTheMiddleOfThePageInView() async throws {
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

    func test_theArrowKeysMoveTheClick() async throws {
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

    func test_escapeLetsGoWithoutAClick() async throws {
        let (viewer, _) = try open()
        let tool = RecordingTool()
        viewer.pointerTool = tool
        viewer.placeWithKeys(.enter)

        XCTAssertTrue(viewer.placeWithKeys(.escape))

        XCTAssertTrue(tool.calls.isEmpty)
        XCTAssertFalse(viewer.placeWithKeys(.right))
    }

    func test_withoutAToolTheKeysAreTheViewers() async throws {
        let (viewer, _) = try open()
        viewer.pointerTool = RecordingTool()
        viewer.pointerTool = nil

        XCTAssertFalse(viewer.placeWithKeys(.enter))
    }

    func test_theTabKeepsThePageTheZoomAndTheFit() async throws {
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

    func test_aTabComesBackAsItWasLeft() async throws {
        let (viewer, first) = try open(pages: 3)
        viewer.zoom = 1.5
        viewer.goToPage(2)
        let second = DocumentTab(session: try PdfEditSession.open(Pdfs.text(2)), renderer: FakeRenderer(), url: nil, title: "b.pdf")

        viewer.show(second)
        viewer.show(first)

        XCTAssertEqual(viewer.pageIndex, 2)
        XCTAssertEqual(viewer.zoom, 1.5, accuracy: 1e-9)
    }

    func test_aTabKeepsItsRotationAndPlaceInThePage() async throws {
        let (viewer, first) = try open(pages: 3)
        viewer.rotation = 90
        viewer.scroll(by: 0, 40)
        let place = viewer.state.topPlace()
        let second = DocumentTab(session: try PdfEditSession.open(Pdfs.text(2)), renderer: FakeRenderer(), url: nil, title: "b.pdf")

        viewer.show(second)
        XCTAssertEqual(viewer.rotation, 0)
        XCTAssertEqual(viewer.pageIndex, 0)
        viewer.show(first)

        XCTAssertEqual(viewer.rotation, 90)
        let back = try XCTUnwrap(viewer.state.topPlace())
        XCTAssertEqual(back.page, try XCTUnwrap(place).page)
        XCTAssertEqual(back.point.y, try XCTUnwrap(place).point.y, accuracy: 1e-6)
    }

    func test_aTabNeverShownBeforeIsNotTurnedLikeTheLastOne() async throws {
        let (viewer, _) = try open()
        viewer.rotation = 90
        let second = DocumentTab(session: try PdfEditSession.open(Pdfs.text(2)), renderer: FakeRenderer(), url: nil, title: "b.pdf")

        viewer.show(second)

        XCTAssertEqual(viewer.rotation, 0)
    }

    func test_aClosedTabIsNotRemembered() async throws {
        let (viewer, first) = try open()
        viewer.rotation = 90
        let second = DocumentTab(session: try PdfEditSession.open(Pdfs.text(2)), renderer: FakeRenderer(), url: nil, title: "b.pdf")
        first.dispose()

        viewer.show(second)
        viewer.show(first)

        XCTAssertEqual(viewer.rotation, 0)
    }

    func test_showingNothingEmptiesTheViewer() async throws {
        let (viewer, _) = try open()

        viewer.show(nil)

        XCTAssertEqual(viewer.pageCount, 0)
        XCTAssertNil(viewer.tab)
        XCTAssertTrue(viewer.visiblePages.isEmpty)
    }

    func test_aPageIsLabelledByTheFileElseByItsNumber() async throws {
        let (viewer, _) = try open(pages: 2)

        XCTAssertEqual(viewer.pageLabel(1), "2")
    }

    func test_readingModeFitsTheWidthAndGivesTheArrangementBack() async throws {
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

    func test_goingBackToOnePageKeepsContinuousScrolling() async throws {
        let (viewer, _) = try open(pages: 3)
        viewer.continuous = true
        viewer.columns = 2

        viewer.columns = 1

        XCTAssertTrue(viewer.continuous)
    }

    func test_aPinchZoomsAboutThePointAndTheZoomStepsKeepToTheUsualOnes() async throws {
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

    func test_aDoubleTapFitsTheWidthAndThenComesIn() async throws {
        let (viewer, _) = try open()
        viewer.zoom = 0.5

        viewer.toggleZoom(about: ViewPoint(100, 100))
        XCTAssertEqual(viewer.fit, .width)
        let fitted = viewer.zoom
        viewer.toggleZoom(about: ViewPoint(100, 100))

        XCTAssertEqual(viewer.zoom, fitted * 2, accuracy: 1e-9)
    }

    func test_theViewRevisionMovesWithTheScroll() async throws {
        let (viewer, _) = try open(pages: 3)
        viewer.zoom = 2
        let before = viewer.viewRevision

        viewer.scroll(by: 0, 120)

        XCTAssertGreaterThan(viewer.viewRevision, before)
        XCTAssertEqual(viewer.offset.y, 120)
    }

    func test_twoWheelScrollsPastTheEdgeTurnOnePage() async throws {
        let (viewer, _) = try open(pages: 5)
        viewer.continuous = false
        viewer.zoom = 2
        viewer.scroll(by: 0, 1_000_000)

        viewer.scroll(by: 0, 100, wheel: true, now: 10)
        viewer.scroll(by: 0, 100, wheel: true, now: 10.1)

        XCTAssertEqual(viewer.pageIndex, 1)
    }

    func test_aWheelEventWithNoMovementDoesNotHoldBackTheTurn() async throws {
        let (viewer, _) = try open(pages: 5)
        viewer.continuous = false
        viewer.zoom = 2
        viewer.scroll(by: 0, 1_000_000)

        viewer.scroll(by: 0, 0, wheel: true, now: 10)
        viewer.scroll(by: 0, 100, wheel: true, now: 10.1)

        XCTAssertEqual(viewer.pageIndex, 1)
    }

    func test_aScrollThatMayNotTurnStopsAtTheEdge() async throws {
        let (viewer, _) = try open(pages: 5)
        viewer.continuous = false
        viewer.zoom = 2
        viewer.scroll(by: 0, 1_000_000)

        viewer.scroll(by: 0, 100, turns: false)

        XCTAssertEqual(viewer.pageIndex, 0)
    }

    func test_aJumpIsInTheHistoryAndScrollingIsNot() async throws {
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

    func test_backReturnsToTheSpotLeftNotTheTopOfThePage() async throws {
        let (viewer, _) = try open(pages: 3)
        viewer.apply(viewer.state.scrollBy(0, 300))
        let spot = viewer.offset.y

        viewer.goToPage(2)
        viewer.goBack()

        XCTAssertEqual(viewer.offset.y, spot, accuracy: 1.5)
        XCTAssertEqual(viewer.pageIndex, 0)
    }

    func test_steppingPagesIsNotAJump() async throws {
        let (viewer, _) = try open(pages: 5)

        viewer.stepPage(1)
        viewer.stepPage(1)
        viewer.stepPage(-1)

        XCTAssertFalse(viewer.canGoBack)
    }

    func test_aSearchSteppedThroughManyHitsIsOneEntryInTheHistory() async throws {
        let (viewer, _) = try open(pages: 3)
        let start = try XCTUnwrap(viewer.state.topPlace())

        await viewer.search.start("tests", TextSearchOptions()).value
        viewer.search.next()
        viewer.search.next()
        viewer.goBack()

        XCTAssertFalse(viewer.canGoBack)
        let back = try XCTUnwrap(viewer.state.topPlace())
        XCTAssertEqual(back.page, start.page)
        XCTAssertEqual(back.point.y, start.point.y, accuracy: 1.5)
    }

    func test_aDestinationAndTheNamedActionsMoveThePage() async throws {
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
        XCTAssertEqual(viewer.pageIndex, 2)
        viewer.follow(NamedAction("Find"))
        XCTAssertTrue(viewer.findVisible)
    }

    func test_anAddressIsOpenedOnlyAfterTheQuestionIsAnswered() async throws {
        let (viewer, _) = try open()

        viewer.follow(UriAction("https://example.com/a"))
        XCTAssertEqual(viewer.pendingAddress, PendingAddress(address: "https://example.com/a", openable: true))
        XCTAssertTrue(opened.isEmpty)
        viewer.openPendingAddress()

        XCTAssertEqual(opened, [URL(string: "https://example.com/a")!])
        XCTAssertNil(viewer.pendingAddress)
    }

    func test_anAddressOfAnotherKindIsShownButNeverOpened() async throws {
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

    func test_anActionTheAppDoesNotRunSaysSo() async throws {
        let (viewer, _) = try open()
        let otherFile = "This link goes to another file, which Lazy PDF does not open from here."
        let script = "This link runs a script or sends a form, which Lazy PDF does not do."

        viewer.follow(GoToRemoteAction("b.pdf", nil, nil))
        XCTAssertEqual(viewer.notice, ViewerNotice(title: otherFile, detail: "b.pdf"))
        viewer.follow(LaunchAction("run.exe", nil))
        XCTAssertEqual(viewer.notice, ViewerNotice(title: otherFile, detail: "run.exe"))
        viewer.follow(SubmitFormAction("https://example.com/post", 0, []))
        XCTAssertEqual(viewer.notice, ViewerNotice(title: script, detail: "https://example.com/post"))
        for action in [JavaScriptAction("app.alert(1)"), ResetFormAction(0, []), OtherAction("Sound")] as [PdfAction] {
            viewer.dismissNotice()
            viewer.follow(action)
            XCTAssertEqual(viewer.notice, ViewerNotice(title: script, detail: nil))
        }
        viewer.dismissNotice()
        XCTAssertNil(viewer.notice)
    }

    func test_aLinkToAMissingPageSaysSoAndLeavesNoHistory() async throws {
        let (viewer, _) = try open()

        viewer.goTo(PdfDestination(9))

        XCTAssertEqual(viewer.notice, ViewerNotice(title: "This link goes to a page that is not in the file.", detail: nil))
        XCTAssertFalse(viewer.canGoBack)
    }

    func test_anAddressStartingWithWwwIsOpenedAsHttps() async throws {
        let (viewer, _) = try open()

        viewer.follow(UriAction(" WWW.example.com/a "))

        XCTAssertEqual(viewer.pendingAddress, PendingAddress(address: "https://WWW.example.com/a", openable: true))
    }

    func test_copyTellsWhyWhenTheFileForbidsIt() async throws {
        let (viewer, _) = try open(bytes: try Pdfs.restricted(.print))
        viewer.selectAll()

        let text = await viewer.selectedText()

        XCTAssertNil(text)
        XCTAssertFalse(viewer.canCopy)
        XCTAssertEqual(viewer.notice?.title, "The owner of this file does not allow copying.")
    }

    func test_copyGivesTheTextOfAFileThatAllowsIt() async throws {
        let (viewer, _) = try open()
        viewer.selectAll()

        let text = await viewer.selectedText()

        XCTAssertEqual(text?.hasPrefix("Hello from"), true)
        XCTAssertNil(viewer.notice)
    }

    func test_thePageBoxTakesANumberAndRefusesWhatIsNotAPage() async throws {
        let (viewer, _) = try open(pages: 3)

        XCTAssertTrue(viewer.goToPage(typed: " 3 "))
        XCTAssertEqual(viewer.pageIndex, 2)
        XCTAssertFalse(viewer.goToPage(typed: "4"))
        XCTAssertFalse(viewer.goToPage(typed: "0"))
        XCTAssertFalse(viewer.goToPage(typed: "x"))
        XCTAssertEqual(viewer.pageIndex, 2)
    }

    func test_pagesStepBySpreadWhenFacingPagesShow() async throws {
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

    func test_handModeDragsThePageAlong() async throws {
        let (viewer, _) = try open(pages: 3)
        viewer.mode = .hand
        viewer.zoom = 1

        viewer.pointerDown(ViewPoint(100, 300))
        viewer.pointerMove(ViewPoint(100, 250))
        viewer.pointerUp(ViewPoint(100, 250))

        XCTAssertEqual(viewer.offset.y, 50, accuracy: 1)
    }

    func test_aPointerToolGetsThePressTheMovesAndTheRelease() async throws {
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

    func test_aFingerGetsNoMovesBetweenPresses() async throws {
        let (viewer, _) = try open()
        let tool = RecordingTool()
        viewer.pointerTool = tool
        let at = try XCTUnwrap(viewer.pageToView(0)).transform(ViewPoint(50, 50))

        viewer.pointerDown(at, touch: true)
        viewer.pointerMove(ViewPoint(at.x + 10, at.y))
        viewer.pointerUp(ViewPoint(at.x + 10, at.y))

        XCTAssertEqual(tool.calls.map(\.kind), ["press", "move", "release"])
        XCTAssertTrue(tool.calls[1].pointer.pressed)
    }

    func test_aFingerThatLandsBetweenPagesGivesTheToolNothing() async throws {
        let (viewer, _) = try open()
        let tool = RecordingTool()
        viewer.pointerTool = tool

        viewer.pointerDown(ViewPoint(-5, -5), touch: true)
        viewer.pointerMove(ViewPoint(-4, -4))
        viewer.pointerUp(ViewPoint(-4, -4))

        XCTAssertTrue(tool.calls.isEmpty)
    }

    func test_aMouseHoversAgainAfterAFingerHasGone() async throws {
        let (viewer, _) = try open()
        let tool = RecordingTool()
        viewer.pointerTool = tool
        let at = try XCTUnwrap(viewer.pageToView(0)).transform(ViewPoint(50, 50))
        viewer.pointerDown(at, touch: true)
        viewer.pointerUp(at)
        tool.calls.removeAll()

        viewer.pointerMove(at)

        XCTAssertEqual(tool.calls.map(\.kind), ["move"])
        XCTAssertFalse(tool.calls[0].pointer.pressed)
    }

    func test_theToolSaysWhetherItTakesAFingerAtAPlace() async throws {
        let (viewer, _) = try open()
        let tool = RecordingTool()
        let at = try XCTUnwrap(viewer.pageToView(0)).transform(ViewPoint(50, 50))
        XCTAssertFalse(viewer.toolTakes(at))

        viewer.pointerTool = tool
        XCTAssertTrue(viewer.toolTakes(at))
        tool.takesAll = false
        XCTAssertFalse(viewer.toolTakes(at))
        tool.takesAll = true
        XCTAssertFalse(viewer.toolTakes(ViewPoint(-5, -5)))
        XCTAssertTrue(tool.calls.isEmpty)
    }

    func test_theToolIsOfferedAKeyFirstAndTheViewerGetsWhatItLeaves() async throws {
        let (viewer, _) = try open(pages: 3)
        let tool = RecordingTool()
        tool.keysTaken = [.delete, .escape]
        viewer.pointerTool = tool
        viewer.showFind()

        XCTAssertTrue(viewer.key(.delete))
        XCTAssertTrue(viewer.key(.escape))
        XCTAssertTrue(viewer.findVisible)
        XCTAssertTrue(viewer.key(.pageDown))
        XCTAssertFalse(viewer.key(.backspace))

        XCTAssertEqual(tool.usedKeys, [.delete, .escape, .pageDown, .backspace])
    }

    func test_escapeDuringAToolPressCancelsIt() async throws {
        let (viewer, _) = try open()
        let tool = RecordingTool()
        viewer.pointerTool = tool
        let at = try XCTUnwrap(viewer.pageToView(0)).transform(ViewPoint(50, 50))
        viewer.pointerDown(at)

        viewer.key(.escape)

        XCTAssertTrue(tool.cancelled)
    }

    func test_escapeClosesTheFindBar() async throws {
        let (viewer, _) = try open()
        viewer.showFind()

        viewer.key(.escape)

        XCTAssertFalse(viewer.findVisible)
    }

    func test_escapeLeavesReadingMode() async throws {
        let (viewer, _) = try open()
        viewer.readingMode = true

        viewer.key(.escape)

        XCTAssertFalse(viewer.readingMode)
    }

    func test_settingAnotherToolCancelsTheOneBefore() async throws {
        let (viewer, _) = try open()
        let first = RecordingTool()
        viewer.pointerTool = first

        viewer.pointerTool = RecordingTool()
        XCTAssertTrue(first.cancelled)
        viewer.mode = .hand

        XCTAssertNil(viewer.pointerTool)
    }

    func test_theKeysScrollAndTurnPages() async throws {
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

    func test_aSelectedWordHasAHandleAtEachEnd() async throws {
        let (viewer, _) = try open()
        let at = try await pointOnFirstLine(viewer, 1)
        XCTAssertNil(viewer.selectionHandles())

        viewer.selectWord(at: at)

        let handles = try XCTUnwrap(viewer.selectionHandles())
        XCTAssertLessThan(handles.start.x, handles.end.x)
        XCTAssertEqual(viewer.handle(at: handles.start, within: 24), true)
        XCTAssertEqual(viewer.handle(at: handles.end, within: 24), false)
        XCTAssertNil(viewer.handle(at: ViewPoint(handles.end.x + 200, handles.end.y + 200), within: 24))
    }

    func test_draggingTheStartHandleKeepsTheEndAndSwapsPastIt() async throws {
        let (viewer, _) = try open()
        let at = try await pointOnFirstLine(viewer, 1)
        let later = try await pointOnFirstLine(viewer, 3)
        let past = try await pointOnFirstLine(viewer, 12)
        viewer.selectWord(at: at)
        let (start, end) = (viewer.selected.start, viewer.selected.end)
        let handles = try XCTUnwrap(viewer.selectionHandles())

        viewer.beginHandleDrag(start: true, at: ViewPoint(handles.start.x, handles.start.y - 7))
        viewer.pointerMove(later)

        XCTAssertEqual(viewer.selected.end, end)
        XCTAssertGreaterThan(viewer.selected.start.index, start.index)
        XCTAssertLessThan(viewer.selected.start.index, end.index)

        viewer.pointerMove(past)
        viewer.pointerUp(past)

        XCTAssertEqual(viewer.selected.start, end)
        XCTAssertGreaterThan(viewer.selected.end.index, end.index)
    }

    func test_aHandleDragGrabbedAtTheBallKeepsTheSelectionUntilTheFingerMoves() async throws {
        let (viewer, _) = try open()
        let at = try await pointOnFirstLine(viewer, 1)
        viewer.selectWord(at: at)
        let before = (viewer.selected.start, viewer.selected.end)
        let handles = try XCTUnwrap(viewer.selectionHandles())
        let ball = ViewPoint(handles.end.x, handles.end.y - 14)
        XCTAssertEqual(viewer.handle(at: ball, within: 24), false)

        viewer.beginHandleDrag(start: false, at: ball)
        viewer.pointerMove(ball)

        XCTAssertEqual(viewer.selected.start, before.0)
        XCTAssertEqual(viewer.selected.end, before.1)
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

    func test_aDoubleClickBeforeTheTextHasLoadedSelectsTheWordOnceItHas() async throws {
        let (known, _) = try open()
        let at = try await pointOnFirstLine(known, 1)
        let (viewer, _) = try open()

        viewer.pointerDown(at, clicks: 2)
        viewer.pointerUp(at)

        await waitFor { viewer.hasSelection }
        let copied = await viewer.selectedText()
        XCTAssertEqual(copied, "Hello")
    }

    func test_aNewerPressBeforeTheTextHasLoadedLeavesTheDoubleClickUnanswered() async throws {
        let (known, _) = try open()
        let at = try await pointOnFirstLine(known, 1)
        let (viewer, _) = try open()

        viewer.pointerDown(at, clicks: 2)
        viewer.pointerUp(at)
        viewer.pointerDown(ViewPoint(at.x, at.y + 200))
        viewer.pointerUp(ViewPoint(at.x, at.y + 200))
        _ = await viewer.text(0)
        await Task.yield()

        XCTAssertFalse(viewer.hasSelection)
    }

    func test_theSecondClickOfADoubleClickOnALinkIsIgnored() async throws {
        let (known, _) = try open()
        let at = try await pointOnFirstLine(known, 1)
        let (viewer, _) = try open()
        viewer.links[0] = [PdfLink(PdfRect(0, 0, 1000, 1000), PdfDestination(1), nil, nil)]
        _ = await viewer.text(0)

        viewer.pointerDown(at)
        viewer.pointerUp(at)
        XCTAssertEqual(viewer.pageIndex, 1)
        viewer.pointerDown(at, clicks: 2)
        viewer.pointerUp(at)

        XCTAssertFalse(viewer.hasSelection)
        XCTAssertEqual(viewer.pageIndex, 1)
    }

    func test_aLongPressOnALinkStillSelectsAWord() async throws {
        let (known, _) = try open()
        let at = try await pointOnFirstLine(known, 1)
        let (viewer, _) = try open()
        viewer.links[0] = [PdfLink(PdfRect(0, 0, 1000, 1000), PdfDestination(1), nil, nil)]
        _ = await viewer.text(0)

        viewer.pointerDown(at, touch: true)
        viewer.pointerUp(at)
        viewer.pointerDown(at, clicks: 2, touch: true)
        viewer.pointerUp(at)

        await waitFor { viewer.hasSelection }
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

    func test_aSelectionOverTwoLinesDoesNotSeedFind() async throws {
        let (viewer, _) = try open(bytes: try Pdfs.text(1, "First line\nSecond line"))
        let from = try await pointOnFirstLine(viewer, 0)
        let to = try await pointOnFirstLine(viewer, 15)
        viewer.pointerDown(from)
        viewer.pointerMove(to)
        viewer.pointerUp(to)

        viewer.showFind()

        XCTAssertNil(viewer.findSeed)
    }

    func test_theLastSearchSurvivesClosingTheBar() async throws {
        let (viewer, _) = try open()
        viewer.showFind()
        await viewer.search.start("tests", TextSearchOptions(matchCase: true)).value

        viewer.hideFind()

        XCTAssertEqual(viewer.lastFind?.text, "tests")
        XCTAssertEqual(viewer.lastFind?.options.matchCase, true)
        XCTAssertEqual(viewer.search.query, "")
    }

    func test_findNextWithTheBarClosedOpensItWithoutStepping() async throws {
        let (viewer, _) = try open()
        let before = viewer.findRequest

        viewer.findNext()

        XCTAssertTrue(viewer.findVisible)
        XCTAssertEqual(viewer.findRequest, before + 1)
        XCTAssertEqual(viewer.search.current, -1)
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

    private func openHalf(previews: Bool, tiles: Bool) throws -> ViewerModel {
        let renderer = HalfRenderer()
        renderer.previews = previews
        renderer.tiles = tiles
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text(1)), renderer: renderer, url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(tab)
        return viewer
    }

    func test_aSharpTileThatFailsIsSaidSoAndAskedForAgainAfterTheZoomSettles() async throws {
        let viewer = try openHalf(previews: true, tiles: false)
        await waitFor { viewer.tilesPending == 0 && !viewer.drawing(of: 0).pictures.isEmpty }

        viewer.zoom = 3
        await waitFor { viewer.drawing(of: 0).partFailed }
        XCTAssertFalse(viewer.drawing(of: 0).failed)
        let scale = viewer.failed.first { !$0.isPreview }?.scale

        viewer.zoom = 3.5
        await waitFor { !viewer.failed.contains { !$0.isPreview && $0.scale == scale } }
    }

    func test_aPreviewThatFailsIsAPageThatCannotBeShownNotAPartOfOne() async throws {
        let viewer = try openHalf(previews: false, tiles: true)

        await waitFor({ viewer.tilesPending == 0 && viewer.drawing(of: 0).failed },
                      "zoom \(viewer.zoom), pending \(viewer.tilesPending), failed \(viewer.failed), "
                          + "pictures \(viewer.drawing(of: 0).pictures.map(\.isPreview))")

        XCTAssertFalse(viewer.drawing(of: 0).partFailed)
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

    func test_aTabThatWasShownAndLeftIsNotKeptAlive() async throws {
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

    func test_pagesDeletedBeforeTheReloadDoNotBreakTheLookups() async throws {
        let (viewer, tab) = try open(pages: 10)
        try PageOperations.delete(tab.document, [4, 5, 6, 7, 8, 9])
        XCTAssertTrue(try tab.commit("Delete pages"))

        _ = viewer.geometry(9)
        XCTAssertNil(viewer.link(at: 9, ViewPoint(10, 10)))
    }

    func test_scrollingInTheContinuousLayoutRedrawsOnlyWhenAsked() async throws {
        let (viewer, _) = try open(pages: 5)
        viewer.zoom = 2
        var redraws = 0
        viewer.onRedraw = { redraws += 1 }

        viewer.redrawsOnScroll = false
        viewer.scrollTo(x: 0, y: 200)
        XCTAssertEqual(redraws, 0)
        XCTAssertEqual(viewer.offset.y, 200, accuracy: 1e-9)

        viewer.redrawsOnScroll = true
        viewer.scrollTo(x: 0, y: 400)
        XCTAssertEqual(redraws, 1)
    }

    func test_aPagedLayoutAndAZoomRedrawEvenWhenScrollingDoesNot() async throws {
        let (viewer, _) = try open(pages: 5)
        viewer.redrawsOnScroll = false
        viewer.zoom = 2
        var redraws = 0
        viewer.onRedraw = { redraws += 1 }

        viewer.zoom = 3
        XCTAssertGreaterThan(redraws, 0)

        viewer.continuous = false
        redraws = 0
        viewer.scrollTo(x: 0, y: 200)
        XCTAssertEqual(redraws, 1)
    }
}
