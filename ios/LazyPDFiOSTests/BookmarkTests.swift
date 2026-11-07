import XCTest
import LazyPDFApp
import LazyPDFIOS

// Follows windows/LazyPDF.App.Tests/RecentFilesTests.cs for the bookmarks of the platform shell.

final class BookmarkTests: XCTestCase {
    private func file() throws -> URL {
        let url = scratch(self).appendingPathComponent("a.pdf")
        try Data(try samplePdf()).write(to: url)
        return url
    }

    func test_aBookmarkLeadsBackToTheFile() throws {
        let url = try file()
        let bookmarks = IOSBookmarks()

        let data = try XCTUnwrap(bookmarks.make(url))
        let resolved = try XCTUnwrap(bookmarks.resolve(data))

        XCTAssertEqual(resolved.url.resolvingSymlinksInPath().path, url.resolvingSymlinksInPath().path)
        XCTAssertFalse(resolved.stale)
    }

    func test_aMovedFileIsFoundThroughItsBookmark() throws {
        let url = try file()
        let bookmarks = IOSBookmarks()
        let data = try XCTUnwrap(bookmarks.make(url))
        let moved = url.deletingLastPathComponent().appendingPathComponent("b.pdf")
        try FileManager.default.moveItem(at: url, to: moved)

        let resolved = try XCTUnwrap(bookmarks.resolve(data))

        XCTAssertEqual(resolved.url.lastPathComponent, "b.pdf")
    }

    func test_aDeletedFileHasNoBookmarkTarget() throws {
        let url = try file()
        let bookmarks = IOSBookmarks()
        let data = try XCTUnwrap(bookmarks.make(url))
        try FileManager.default.removeItem(at: url)

        XCTAssertNil(bookmarks.resolve(data))
    }

    func test_dataThatIsNoBookmarkDoesNotResolve() {
        XCTAssertNil(IOSBookmarks().resolve(Data("not a bookmark".utf8)))
    }

    func test_anAccessToAFileOfTheAppsOwnCanBeStoppedAndTheFileStaysReadable() throws {
        let url = try file()

        let access = IOSBookmarks().access(url)
        access?.stop()
        access?.stop()

        XCTAssertFalse(try Data(contentsOf: url).isEmpty)
    }

    func test_stoppingAnAccessEndsItExactlyOnce() {
        var ended: [URL] = []
        let url = URL(fileURLWithPath: "/tmp/a.pdf")
        let access = SecurityScopedAccess(url) { ended.append($0) }

        access.stop()
        access.stop()

        XCTAssertEqual(ended, [url])
    }

    func test_anAccessThatWasNeverStoppedEndsWhenItGoes() {
        var ended = 0
        var access: SecurityScopedAccess? = SecurityScopedAccess(URL(fileURLWithPath: "/tmp/a.pdf")) { _ in ended += 1 }

        access?.stop()
        access = nil

        XCTAssertEqual(ended, 1)
    }
}
