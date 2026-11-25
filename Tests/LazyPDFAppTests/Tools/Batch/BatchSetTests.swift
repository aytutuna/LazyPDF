import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/measure/BatchSetTests.cs: names from the template, saved sets, and the folder watcher.
// The template cases keep the Windows ones and add the .NET formats this port reads. The watcher tests run on the Mac, the
// only place the watch is offered.

final class BatchSetTests: XCTestCase {
    private let date = DateTimeOffset(2026, 3, 9, 12, 0, 0)

    func test_theTemplateMakesTheFileName() {
        let cases = [("{name}", "invoice.pdf"), ("", "invoice.pdf"), ("{name}-clean", "invoice-clean.pdf"),
                     ("{date}_{name}", "2026-03-09_invoice.pdf"), ("{date:yyyyMMdd}-{n:000}", "20260309-004.pdf"),
                     ("{name}.pdf", "invoice.pdf"), ("a/b:{name}", "a_b_invoice.pdf"), ("{other}", "{other}.pdf"),
                     ("{n:D3}", "004.pdf"), ("{date:HH.mm}", "12.00.pdf"), ("{date:'at' h tt}", "at 12 PM.pdf"),
                     ("{date:MMMM}", "{date_MMMM}.pdf"), ("{name}..", "invoice.pdf")]
        for (template, expected) in cases {
            XCTAssertEqual(BatchNames.apply(template, "invoice", 4, date), expected, template)
        }
    }

    func test_setsAreKeptByNameWithTheirSettings() throws {
        let dir = TempDir(self)
        let store = BatchSetStore(directory: dir.url)
        var bates = BatchStep(.bates)
        bates.text = "X-"
        bates.digits = 8
        bates.start = 40
        var compress = BatchStep(.compress)
        compress.preset = .small
        var pdfA = BatchStep(.pdfA)
        pdfA.level = .a3u
        var pdfUa = BatchStep(.pdfUa)
        pdfUa.markPdfUa = true
        let steps = [bates, compress, pdfA, pdfUa]

        store.save(BatchSet(name: "Cases", steps: steps, outputFolder: "/out", nameTemplate: "{name}-b", watchFolder: "/in"))
        store.save(BatchSet(name: "Other"))
        store.save(BatchSet(name: "cases", outputFolder: "/again"))

        let loaded = BatchSetStore(directory: dir.url).load()
        XCTAssertEqual(loaded.map(\.name).sorted(), ["Other", "cases"])
        XCTAssertEqual(loaded.first { $0.name == "cases" }?.outputFolder, "/again")

        store.save(BatchSet(name: "Cases", steps: steps, nameTemplate: "{name}-b"))
        let back = try XCTUnwrap(BatchSetStore(directory: dir.url).load().first { $0.name == "Cases" })
        XCTAssertEqual(back.steps.map(\.kind), [.bates, .compress, .pdfA, .pdfUa])
        XCTAssertEqual(back.steps[0].text, "X-")
        XCTAssertEqual(back.steps[0].digits, 8)
        XCTAssertEqual(back.steps[0].start, 40)
        XCTAssertEqual(back.steps[1].preset, .small)
        XCTAssertEqual(back.steps[2].level, .a3u)
        XCTAssertTrue(back.steps[3].markPdfUa)
        XCTAssertEqual(back.nameTemplate, "{name}-b")

        store.delete("cases")
        XCTAssertEqual(BatchSetStore(directory: dir.url).load().map(\.name), ["Other"])
    }

    func test_aSetKeepsTheBookmarksOfItsFolders() {
        let dir = TempDir(self)
        var set = BatchSet(name: "Cases", outputFolder: "/out", watchFolder: "/in")
        set.outputBookmark = Data("out".utf8)
        set.watchBookmark = Data("in".utf8)

        BatchSetStore(directory: dir.url).save(set)

        let back = BatchSetStore(directory: dir.url).load().first
        XCTAssertEqual(back?.outputBookmark, Data("out".utf8))
        XCTAssertEqual(back?.watchBookmark, Data("in".utf8))
    }

    func test_aSetsFileMissingKeysReadsWithTheirDefaults() throws {
        let dir = TempDir(self)
        dir.file("batch-sets.json", Array(#"{"sets":[{"name":"Old","steps":[{"kind":2}]}]}"#.utf8))

        let set = try XCTUnwrap(BatchSetStore(directory: dir.url).load().first)

        XCTAssertEqual(set.nameTemplate, "{name}")
        XCTAssertEqual(set.steps.first?.kind, .clean)
        XCTAssertEqual(set.steps.first?.opacity, 30)
    }

    func test_aNewCleanStepKeepsWhatAReaderSeesButADecodedOneKeepsWhatItStored() throws {
        let step = BatchStep.of(.clean)
        XCTAssertTrue(step.keepComments && step.keepForms && step.keepLinks)
        XCTAssertFalse(step.keepAttachments)

        let old = try JSONDecoder().decode(BatchStep.self, from: Data(#"{"kind":2}"#.utf8))
        XCTAssertFalse(old.keepComments || old.keepForms || old.keepLinks)
    }

    func test_anUnreadableSetsFileGivesNoSets() {
        let dir = TempDir(self)
        dir.file("batch-sets.json", Array("not json".utf8))

        XCTAssertTrue(BatchSetStore(directory: dir.url).load().isEmpty)
    }

    func test_aCopyDoesNotFollowLaterEdits() {
        var watermark = BatchStep(.watermark)
        watermark.text = "A"
        var set = BatchSet(steps: [watermark])

        let copy = set
        set.steps[0].text = "B"
        set.steps.append(BatchStep(.clean))

        XCTAssertEqual(copy.steps.map(\.text), ["A"])
    }

    #if os(macOS)
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var onFirst: (() -> Void)?

        func add(_ url: URL) {
            lock.lock()
            urls.append(url)
            let first = urls.count == 1
            lock.unlock()
            if first { onFirst?() }
        }

        var all: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    func test_theWatcherReportsANewPdfOnceAndNotTheOnesAlreadyThere() async throws {
        let dir = TempDir(self)
        dir.file("old.pdf", Pdfs.text())
        let found = Found()
        let first = expectation(description: "a new pdf")
        found.onFirst = { first.fulfill() }
        let watcher = try FolderWatcher(folder: dir.url, delay: 0.1, found: { found.add($0) }, failed: {})
        defer { watcher.stop() }

        let made = dir.file("new.pdf", Pdfs.text())
        dir.file("note.txt", [1])

        await fulfillment(of: [first], timeout: 10)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(found.all.map(\.lastPathComponent), [made.lastPathComponent])
    }

    func test_aFileThatLeavesAndComesBackIsReportedAgain() async throws {
        let dir = TempDir(self)
        let aside = TempDir(self)
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: aside.url, withIntermediateDirectories: true)
        let found = Found()
        let first = expectation(description: "first")
        found.onFirst = { first.fulfill() }
        let watcher = try FolderWatcher(folder: dir.url, delay: 0.1, found: { found.add($0) }, failed: {})
        defer { watcher.stop() }
        let made = dir.file("a.pdf", Pdfs.text())
        await fulfillment(of: [first], timeout: 10)

        let away = aside.sub("a.pdf")
        try FileManager.default.moveItem(at: made, to: away)
        try await Task.sleep(nanoseconds: 600_000_000)
        try FileManager.default.moveItem(at: away, to: made)

        await waitUntil { found.all.count == 2 }
    }

    func test_aFileThatGrowsAfterItWasReportedIsReportedAgainWhenItSettles() async throws {
        let dir = TempDir(self)
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let found = Found()
        let first = expectation(description: "first")
        found.onFirst = { first.fulfill() }
        let watcher = try FolderWatcher(folder: dir.url, delay: 0.1, found: { found.add($0) }, failed: {})
        defer { watcher.stop() }
        let made = dir.file("a.pdf", [UInt8](Pdfs.text(2).prefix(60)))
        await fulfillment(of: [first], timeout: 10)

        let handle = try FileHandle(forWritingTo: made)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(Pdfs.text(2).dropFirst(60)))
        try handle.close()

        await waitUntil { found.all.count == 2 }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(found.all.count, 2)
    }

    func test_nothingIsReportedAfterTheWatcherIsStopped() async throws {
        let dir = TempDir(self)
        dir.file("old.pdf", Pdfs.text())
        let found = Found()
        let watcher = try FolderWatcher(folder: dir.url, delay: 0.1, found: { found.add($0) }, failed: {})

        dir.file("new.pdf", Pdfs.text())
        watcher.stop()
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertTrue(found.all.isEmpty)
    }

    func test_aFolderThatGoesAwayIsReported() async throws {
        let dir = TempDir(self)
        let folder = dir.sub("watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let gone = expectation(description: "failed")
        let watcher = try FolderWatcher(folder: folder, delay: 0.1, found: { _ in }, failed: { gone.fulfill() })
        defer { watcher.stop() }

        try FileManager.default.removeItem(at: folder)

        await fulfillment(of: [gone], timeout: 10)
    }

    func test_aFolderThatIsNotThereCannotBeWatched() {
        let dir = TempDir(self)

        XCTAssertThrowsError(try FolderWatcher(folder: dir.sub("missing"), found: { _ in }, failed: {}))
    }
    #endif
}
