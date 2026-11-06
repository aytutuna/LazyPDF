import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/RecentFilesTests.cs, with a stand-in for the bookmarks. The paths come from a folder
// of the test's own, so they are real paths on every system.

final class RecentFilesTests: XCTestCase {
    private func recent(_ dir: TempDir, _ bookmarks: PathBookmarks = PathBookmarks()) -> RecentFiles {
        RecentFiles(directory: dir.url, bookmarks: bookmarks)
    }

    // Names that differ by case are one file only on a volume that ignores case.
    private func skipOnCaseSensitiveVolume(_ dir: TempDir) throws {
        try? FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let sensitive = (try? dir.url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames
        try XCTSkipIf(sensitive == true, "the volume tells names apart by case")
    }

    private func paths(_ recent: RecentFiles) -> [String] {
        recent.load().map(\.path)
    }

    private func key(_ url: URL) -> String {
        RecentFiles.key(url)
    }

    func test_theNewestIsFirst() {
        let dir = TempDir(self)
        let recent = recent(dir)
        let a = dir.sub("docs/a.pdf"), b = dir.sub("docs/b.pdf")
        recent.add(a)
        recent.add(b)

        XCTAssertEqual(paths(recent), [key(b), key(a)])
    }

    func test_openingAgainMovesItToTheFrontWithoutADuplicate() throws {
        let dir = TempDir(self)
        try skipOnCaseSensitiveVolume(dir)
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

    func test_removeAndClearTakeEntriesOut() throws {
        let dir = TempDir(self)
        try skipOnCaseSensitiveVolume(dir)
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

    func test_aMovedFileIsListedOnceAndForgottenWithItsOldEntry() {
        let dir = TempDir(self)
        let bookmarks = PathBookmarks()
        let recent = recent(dir, bookmarks)
        let a = dir.sub("docs/a.pdf"), b = dir.sub("docs/b.pdf")
        recent.add(a)
        bookmarks.moved[a.standardizedFileURL.path] = b.standardizedFileURL.path

        XCTAssertTrue(samePath(recent.locate(recent.load()[0]), b))
        recent.add(b)
        XCTAssertEqual(recent.load().count, 1)

        recent.remove(b)
        XCTAssertTrue(recent.load().isEmpty)
    }

    func test_aStaleBookmarkIsMadeAgain() {
        let dir = TempDir(self)
        let bookmarks = PathBookmarks()
        let recent = recent(dir, bookmarks)
        let a = dir.sub("docs/a.pdf"), b = dir.sub("docs/b.pdf")
        recent.add(a)
        bookmarks.moved[a.standardizedFileURL.path] = b.standardizedFileURL.path
        bookmarks.stale = true

        _ = recent.locate(recent.load()[0])

        XCTAssertEqual(recent.load()[0].bookmark, Data(b.standardizedFileURL.path.utf8))
    }

    func test_oneFileReachedThroughALinkHasOneEntry() throws {
        let dir = TempDir(self)
        let file = dir.file("docs/a.pdf", Pdfs.text())
        let link = dir.sub("link")
        try XCTSkipIf((try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.sub("docs"))) == nil,
                      "no symbolic links here")
        let recent = recent(dir)

        recent.add(file)
        recent.add(link.appendingPathComponent("a.pdf"))

        XCTAssertEqual(recent.load().count, 1)
    }

    func test_oneNameInTwoUnicodeFormsIsOneKey() {
        let composed = URL(fileURLWithPath: "/docs/caf\u{E9}.pdf")
        let decomposed = URL(fileURLWithPath: "/docs/cafe\u{301}.pdf")

        XCTAssertEqual(RecentFiles.key(composed), RecentFiles.key(decomposed))
    }
}
