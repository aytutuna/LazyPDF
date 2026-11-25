import LazyPDFKit
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
    private func pictures(_ f: ViewModelFixture) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: f.folders.thumbnails.path)) ?? []
        return files.filter { $0.hasSuffix(".png") }
    }

    func test_forgettingARecentFileRemovesItsPictureOnly() async {
        let f = ViewModelFixture(self)
        let a = f.pdf("a.pdf"), b = f.pdf("b.pdf")
        _ = await f.vm.thumbnail(of: item(a))
        _ = await f.vm.thumbnail(of: item(b))
        XCTAssertEqual(pictures(f).count, 2)

        f.vm.forgetRecent(a)

        XCTAssertEqual(pictures(f).count, 1)
        let kept = await f.vm.thumbnail(of: item(b))
        XCTAssertNotNil(kept)
        XCTAssertEqual(pictures(f).count, 1)
    }

    func test_clearingTheRecentListEmptiesTheThumbnailFolder() async {
        let f = ViewModelFixture(self)
        _ = await f.vm.thumbnail(of: item(f.pdf("a.pdf")))
        _ = await f.vm.thumbnail(of: item(f.pdf("b.pdf")))

        f.vm.clearRecent()

        XCTAssertTrue(pictures(f).isEmpty)
    }

    func test_aProtectedFileGivesNoPicture() async {
        let f = ViewModelFixture(self)

        let locked = await f.vm.thumbnail(of: item(f.locked()))
        let recipients = await f.vm.thumbnail(of: item(f.dir.file("r.pdf", Pdfs.forRecipients())))

        XCTAssertNil(locked)
        XCTAssertNil(recipients)
        XCTAssertTrue(pictures(f).isEmpty)
    }

    func test_aPictureFinishedAfterClearIsNotWritten() async {
        let f = ViewModelFixture(self)
        let file = f.pdf()
        let started = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let thumbnails = Thumbnails({ WaitingRenderer(started, go) }, directory: f.folders.thumbnails)

        let task = Task.detached { await thumbnails.get(file) }
        started.wait()
        thumbnails.clear()
        go.signal()
        let png = await task.value

        XCTAssertNotNil(png)
        XCTAssertTrue(pictures(f).isEmpty)
    }
}

private final class WaitingRenderer: DocumentRenderer {
    let started: DispatchSemaphore
    let go: DispatchSemaphore

    init(_ started: DispatchSemaphore, _ go: DispatchSemaphore) {
        self.started = started
        self.go = go
    }

    func load(_ session: PdfEditSession, _ password: String?) -> Bool { true }
    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (200, 300) }

    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
        started.signal()
        go.wait()
        return PdfRgbaImage(4, 6, [UInt8](repeating: 255, count: 4 * 6 * 4))
    }

    func close() {}
}
