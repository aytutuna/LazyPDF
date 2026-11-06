import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/RecentFilesTests.cs, with a stand-in for the bookmarks. The paths come from a folder
// of the test's own, so they are real paths on every system.

final class RecentFilesTests: XCTestCase {
    private func recent(_ dir: TempDir) -> RecentFiles {
        RecentFiles(directory: dir.url, bookmarks: PathBookmarks())
    }

    private func paths(_ recent: RecentFiles) -> [String] {
        recent.load().map(\.path)
    }

    private func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    func test_theNewestIsFirst() {
        let dir = TempDir(self)
        let recent = recent(dir)
        let a = dir.sub("docs/a.pdf"), b = dir.sub("docs/b.pdf")
        recent.add(a)
        recent.add(b)

        XCTAssertEqual(paths(recent), [key(b), key(a)])
    }

    func test_openingAgainMovesItToTheFrontWithoutADuplicate() {
        let dir = TempDir(self)
        let recent = recent(dir)
        recent.add(dir.sub("docs/a.pdf"))
        recent.add(dir.sub("docs/b.pdf"))
        let shouting = URL(fileURLWithPath: key(dir.sub("docs/a.pdf")).uppercased())
        recent.add(shouting)

        XCTAssertEqual(recent.load().count, 2)
        XCTAssertEqual(recent.load()[0].path, key(shouting))
    }

    func test_theListIsCutAtItsLimit() {
        let dir = TempDir(self)
        let recent = recent(dir)
        for i in 0..<(RecentFiles.limit + 5) { recent.add(dir.sub("docs/\(i).pdf")) }

        let files = recent.load()

        XCTAssertEqual(files.count, RecentFiles.limit)
        XCTAssertEqual(files[0].path, key(dir.sub("docs/\(RecentFiles.limit + 4).pdf")))
    }

    func test_removeAndClearTakeEntriesOut() {
        let dir = TempDir(self)
        let recent = recent(dir)
        recent.add(dir.sub("docs/a.pdf"))
        recent.add(dir.sub("docs/b.pdf"))

        recent.remove(URL(fileURLWithPath: key(dir.sub("docs/a.pdf")).uppercased()))
        XCTAssertEqual(paths(recent), [key(dir.sub("docs/b.pdf"))])

        recent.clear()
        XCTAssertTrue(recent.load().isEmpty)
    }

    func test_itSurvivesTheNextStart() {
        let dir = TempDir(self)
        let when = Date(timeIntervalSince1970: 1_772_355_600.123)
        recent(dir).add(dir.sub("docs/a.pdf"), now: when)

        let loaded = recent(dir).load()

        XCTAssertEqual(loaded[0].opened, when)
    }

    func test_aFileIsFoundAgainThroughItsBookmark() {
        let dir = TempDir(self)
        let recent = recent(dir)
        let url = dir.sub("docs/a.pdf")
        recent.add(url)

        XCTAssertTrue(samePath(recent.locate(recent.load()[0]), url))
    }
}
