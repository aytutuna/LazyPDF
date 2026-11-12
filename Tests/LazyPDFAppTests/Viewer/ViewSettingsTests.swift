import XCTest
@testable import LazyPDFApp

// Windows keeps the page tint and arrangement in its preferences file; so do the Apple viewers.

@MainActor
final class ViewSettingsTests: XCTestCase {
    private func viewer(_ dir: TempDir) -> ViewerModel {
        ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in }, settings: dir.url)
    }

    func test_aFreshViewerStartsPlain() async {
        let dir = TempDir(self)
        let made = viewer(dir)

        XCTAssertEqual(made.tint, .none)
        XCTAssertEqual(made.columns, 1)
        XCTAssertFalse(made.coverPage)
        XCTAssertTrue(made.continuous)
    }

    func test_tintAndArrangementComeBackOnTheNextStart() async {
        let dir = TempDir(self)
        let first = viewer(dir)
        first.tint = .sepia
        first.columns = 2
        first.coverPage = true
        first.continuous = false

        let second = viewer(dir)

        XCTAssertEqual(second.tint, .sepia)
        XCTAssertEqual(second.columns, 2)
        XCTAssertTrue(second.coverPage)
        XCTAssertFalse(second.continuous)
    }

    func test_readingModeDoesNotChangeWhatIsKept() async {
        let dir = TempDir(self)
        let first = viewer(dir)
        first.columns = 2
        first.readingMode = true

        XCTAssertEqual(viewer(dir).columns, 2)
    }

    func test_aViewerWithoutAFolderKeepsNothing() async {
        let dir = TempDir(self)
        let made = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        made.tint = .dark

        XCTAssertEqual(viewer(dir).tint, .none)
    }
}
