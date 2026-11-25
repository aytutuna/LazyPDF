import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The side by side sheet's state: a mark for each difference on the pages in view, the picture of a page in overlay mode, the
// jump to a row, and the two views following each other. Windows has no test of the window; the pair of pages ViewSync follows
// is tested with ViewSyncPartnerTests.

@MainActor
final class CompareWindowModelTests: XCTestCase {
    private func window() async throws -> (window: CompareWindowModel, session: CompareSession) {
        let session = try await CompareKit.session(CompareKit.before(), CompareKit.after())
        let window = CompareWindowModel(session, session.rows(.all), { FakeRenderer() })
        window.oldViewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        window.newViewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        return (window, session)
    }

    private func marks(_ viewer: ViewerModel, _ page: Int = 0) -> [OverlayItem] {
        viewer.overlay(page).items.filter { $0.id.hasPrefix("compare.m.") }
    }

    func test_theTitlesNameTheTwoFiles() async throws {
        let (window, session) = try await window()
        defer { window.close(); session.dispose() }

        XCTAssertEqual(window.title, "Comparison of old.pdf and new.pdf")
        XCTAssertEqual(window.oldTitle, "Old: old.pdf")
        XCTAssertEqual(window.newTitle, "New: new.pdf")
        XCTAssertEqual(window.legend, "Green is added, red is removed, amber is changed or moved.")
    }

    func test_aMarkIsPaintedForEachDifferenceOnThePagesInView() async throws {
        let (window, session) = try await window()
        defer { window.close(); session.dispose() }

        await waitUntil { !self.marks(window.newViewer).isEmpty }

        let added = window.rows.filter { $0.kind == .added && $0.newPage == 0 }.reduce(0) { $0 + $1.newBoxes.count }
        XCTAssertGreaterThan(added, 0)
        XCTAssertTrue(marks(window.newViewer).contains { $0.style.fill?.green ?? 0 > 0.6 && $0.style.fill?.red ?? 1 < 0.3 })
    }

    func test_aMarkOfNoWidthIsStillVisible() async throws {
        let (window, session) = try await window()
        defer { window.close(); session.dispose() }
        let row = ChangeRow(kind: .removed, title: "Gone", subtitle: "", oldPage: 0, newPage: 0, oldBoxes: [ViewRect(10, 10, 0, 12)], newBoxes: [])

        window.setRows([row])
        await waitUntil { !self.marks(window.oldViewer).isEmpty }

        guard case .rect(let area) = marks(window.oldViewer)[0].shape else { return XCTFail("a box") }
        XCTAssertEqual(area.width, 3)
        XCTAssertEqual(area.x, 8.5)
    }

    func test_newRowsReplaceTheMarks() async throws {
        let (window, session) = try await window()
        defer { window.close(); session.dispose() }
        await waitUntil { !self.marks(window.newViewer).isEmpty }

        window.setRows([])

        XCTAssertTrue(marks(window.newViewer).isEmpty)
        XCTAssertTrue(marks(window.oldViewer).isEmpty)
    }

    func test_aRowTakesBothViewsToItsPageAndOverlayModeOnlyTheNewOne() async throws {
        let (window, session) = try await window()
        defer { window.close(); session.dispose() }
        let row = ChangeRow(kind: .added, title: "More", subtitle: "", oldPage: 1, newPage: 1, oldBoxes: [], newBoxes: [])

        window.setOverlay(true)
        window.go(row)
        XCTAssertEqual(window.newViewer.pageIndex, 1)
        XCTAssertEqual(window.oldViewer.pageIndex, 0)

        window.setOverlay(false)
        window.go(row)
        XCTAssertEqual(window.oldViewer.pageIndex, 1)
    }

    func test_aRowIsNotUndoneByTheViewsFollowingEachOther() async throws {
        let (window, session) = try await window()
        defer { window.close(); session.dispose() }

        window.go(ChangeRow(kind: .changed, title: "Moved", subtitle: "", oldPage: 1, newPage: 0, oldBoxes: [], newBoxes: []))
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(window.oldViewer.pageIndex, 1)
        XCTAssertEqual(window.newViewer.pageIndex, 0)
    }

    func test_aRowWithNoPageOnASideLeavesThatSideAlone() async throws {
        let (window, session) = try await window()
        defer { window.close(); session.dispose() }

        window.go(ChangeRow(kind: .removed, title: "Gone", subtitle: "", oldPage: 1, newPage: -1, oldBoxes: [], newBoxes: []))

        XCTAssertEqual(window.oldViewer.pageIndex, 1)
        XCTAssertEqual(window.newViewer.pageIndex, 0)
    }

    func test_overlayModeShowsThePictureOfThePageAndSideBySideTakesItAway() async throws {
        let (window, session) = try await window()
        defer { window.close(); session.dispose() }

        window.setOverlay(true)
        await waitUntil { window.newViewer.overlay(0).item("compare.p.0") != nil }
        XCTAssertEqual(window.newViewer.overlay(0).item("compare.p.0")?.layer, -1)

        window.setOverlay(false)
        XCTAssertNil(window.newViewer.overlay(0).item("compare.p.0"))
    }

    func test_closingEndsTheMarksAndLetsGoOfTheFiles() async throws {
        let (window, session) = try await window()
        defer { session.dispose() }
        await waitUntil { !self.marks(window.newViewer).isEmpty }

        window.close()

        XCTAssertTrue(window.isClosed)
        XCTAssertNil(window.newViewer.tab)
        XCTAssertNil(window.oldViewer.tab)
        window.close()
    }

    func test_scrollingOneViewMovesTheOtherToThePartnerPage() async throws {
        let (window, session) = try await window()
        defer { window.close(); session.dispose() }

        window.oldViewer.goToPage(1)

        await waitUntil { window.newViewer.pageIndex == 1 }
    }

    func test_switchingTheLinkOffLeavesTheOtherViewWhereItIs() async throws {
        let (window, session) = try await window()
        defer { window.close(); session.dispose() }
        window.setLinked(false)

        window.oldViewer.goToPage(1)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(window.newViewer.pageIndex, 0)
        XCTAssertFalse(window.linked)
    }
}
