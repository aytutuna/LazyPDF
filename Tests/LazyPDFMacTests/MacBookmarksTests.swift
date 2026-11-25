#if os(macOS)
import XCTest
@testable import LazyPDFMac
import LazyPDFApp

// Not in the Windows tests: the Windows app keeps plain paths. The bookmarks are made and resolved against real files.

final class MacBookmarksTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-mac-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func same(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    func test_aBookmarkLeadsBackToTheFile() throws {
        let file = try folder().appendingPathComponent("a.pdf")
        try Data([1]).write(to: file)
        let bookmarks = MacBookmarks()

        let data = try XCTUnwrap(bookmarks.make(file))
        let resolved = try XCTUnwrap(bookmarks.resolve(data))

        XCTAssertTrue(same(resolved.url, file))
        XCTAssertFalse(resolved.stale)
    }

    func test_aBookmarkFollowsAFileThatWasMoved() throws {
        let dir = try folder()
        let file = dir.appendingPathComponent("a.pdf")
        let moved = dir.appendingPathComponent("b.pdf")
        try Data([1]).write(to: file)
        let bookmarks = MacBookmarks()
        let data = try XCTUnwrap(bookmarks.make(file))

        try FileManager.default.moveItem(at: file, to: moved)

        XCTAssertTrue(same(try XCTUnwrap(bookmarks.resolve(data)).url, moved))
    }

    func test_aBookmarkOfAFileThatIsGoneLeadsNowhere() throws {
        let file = try folder().appendingPathComponent("a.pdf")
        try Data([1]).write(to: file)
        let bookmarks = MacBookmarks()
        let data = try XCTUnwrap(bookmarks.make(file))

        try FileManager.default.removeItem(at: file)

        XCTAssertNil(bookmarks.resolve(data))
    }

    func test_bytesThatAreNoBookmarkLeadNowhere() {
        XCTAssertNil(MacBookmarks().resolve(Data([1, 2, 3])))
    }

    func test_aFileThatCannotBeBookmarkedGivesNil() throws {
        XCTAssertNil(MacBookmarks().make(try folder().appendingPathComponent("missing.pdf")))
    }
}
#endif
