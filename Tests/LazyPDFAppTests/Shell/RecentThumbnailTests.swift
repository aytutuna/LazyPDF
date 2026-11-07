import XCTest
@testable import LazyPDFApp

@MainActor
final class RecentThumbnailTests: XCTestCase {
    private func item(_ url: URL, exists: Bool = true) -> RecentItem {
        RecentItem(url: url, name: url.lastPathComponent, folder: "", opened: "Today", exists: exists)
    }

    func test_aRecentFileGivesAPictureAndItsAccessEnds() async throws {
        let f = ViewModelFixture(self)

        let png = await f.vm.thumbnail(of: item(f.pdf()))

        XCTAssertEqual(try XCTUnwrap(png).prefix(4).map { $0 }, [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(f.bookmarks.grants.map(\.stops), [1])
    }

    func test_aFileThatIsGoneGivesNoPictureAndNoAccessIsStarted() async {
        let f = ViewModelFixture(self)

        let png = await f.vm.thumbnail(of: item(f.dir.url.appendingPathComponent("gone.pdf"), exists: false))

        XCTAssertNil(png)
        XCTAssertTrue(f.bookmarks.grants.isEmpty)
    }
}
