import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Batch panel as the sheet and the tool strip drive it: the steps, the files and folders, the run and its log, the saved
// sets and the watched folder. Windows has no test of the panel itself; the steps are tested with BatchRunnerTests and the
// names and sets with BatchSetTests. The folder watcher is a stand-in here, since the real one is the Mac's.

@MainActor
private final class Picker: ToolFilePicker {
    var files: [ToolFile] = []
    var folder: ToolFile?

    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] { files }
    func pickFolder() async -> ToolFile? { folder }
}

private final class FakeWatch: FolderWatching {
    private(set) var stops = 0
    func stop() { stops += 1 }
}

@MainActor
private final class WatchLog {
    let watch = FakeWatch()
    var folders: [URL] = []
    var found: (@Sendable (URL) -> Void)?
    var failed: (@Sendable () -> Void)?
    var refuses = false

    var factory: FolderWatchFactory {
        { [self] folder, found, failed in
            if refuses { throw CocoaError(.fileReadNoPermission) }
            folders.append(folder)
            self.found = found
            self.failed = failed
            return watch
        }
    }
}

@MainActor
final class BatchModelTests: XCTestCase {
    private func runner() -> BatchRunner {
        BatchRunner(codec: FakeCodec(), fonts: batchFonts(), recognizer: FakeRecognizer(), renderers: { FakeRenderer() })
    }

    private func make(_ f: ViewModelFixture, watch: WatchLog? = nil, bookmarks: Bookmarks? = nil) -> (model: BatchModel, picker: Picker) {
        let picker = Picker()
        f.vm.filePicker = picker
        let model = BatchModel(host: f.vm, settings: f.dir.sub("settings"), bookmarks: bookmarks, watcher: watch?.factory, runner: { [self] in runner() })
        return (model, picker)
    }

    private func folder(_ f: ViewModelFixture, _ name: String) throws -> ToolFile {
        let url = f.dir.sub(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ToolFile(url: url)
    }

    func test_stepsAreAddedMovedAndRemovedAndTheSelectionFollows() {
        let f = ViewModelFixture(self)
        let (model, _) = make(f)
        XCTAssertNil(model.step)
        XCTAssertFalse(model.canMoveUp)

        model.addStep(.clean)
        model.addStep(.watermark)
        model.addStep(.compress)
        XCTAssertEqual(model.set.steps.map(\.kind), [.clean, .watermark, .compress])
        XCTAssertEqual(model.step?.kind, .compress)
        XCTAssertFalse(model.canMoveDown)

        model.moveSelected(-1)
        XCTAssertEqual(model.set.steps.map(\.kind), [.clean, .compress, .watermark])
        XCTAssertEqual(model.selected, 1)
        model.moveSelected(-1)
        model.moveSelected(-1)
        XCTAssertEqual(model.set.steps.map(\.kind), [.compress, .clean, .watermark])
        XCTAssertFalse(model.canMoveUp)

        model.removeSelected()
        XCTAssertEqual(model.set.steps.map(\.kind), [.clean, .watermark])
        XCTAssertNil(model.step)
        XCTAssertEqual(model.rows.map(\.title), ["Clean for sharing", "Watermark"])
    }

    func test_theBoxesTakeNumbersWithinTheirLimitsAndKeepTheOldOneOtherwise() {
        let f = ViewModelFixture(self)
        let (model, _) = make(f)
        model.addStep(.watermark)

        model.setOpacity("1")
        XCTAssertEqual(model.step?.opacity, 5)
        model.setOpacity("250")
        XCTAssertEqual(model.step?.opacity, 100)
        model.setOpacity("abc")
        XCTAssertEqual(model.step?.opacity, 100)
        model.setAngle("-999")
        XCTAssertEqual(model.step?.angle, -360)
        model.setSize("5")
        XCTAssertEqual(model.step?.size, 10)

        model.addStep(.bates)
        model.setDigits("40")
        XCTAssertEqual(model.step?.digits, 18)
        model.setStart("-3")
        XCTAssertEqual(model.step?.start, 1)
        model.setStart(" 12 ")
        XCTAssertEqual(model.step?.start, 12)
    }

    func test_theDetailOfAStepFollowsItsSettings() {
        var clean = BatchStep(.clean)
        XCTAssertEqual(BatchText.detail(clean), "Removes hidden and private data")
        clean.keepLinks = true
        XCTAssertEqual(BatchText.detail(clean), "Keeps some private data")
        var watermark = BatchStep(.watermark)
        XCTAssertEqual(BatchText.detail(watermark), "No text yet")
        watermark.text = "DRAFT"
        XCTAssertEqual(BatchText.detail(watermark), "DRAFT")
        var bates = BatchStep(.bates)
        bates.text = "AB-"
        bates.digits = 4
        bates.start = 7
        XCTAssertEqual(BatchText.detail(bates), "Starts at AB-0007")
        XCTAssertEqual(BatchText.anchorName(.bottomRight), "Bottom right")
        XCTAssertEqual(BatchText.placeName(.headerLeft), "Header, left")
    }

    func test_theButtonNeedsFilesStepsAndAResultsFolder() async throws {
        let f = ViewModelFixture(self)
        let (model, picker) = make(f)
        XCTAssertFalse(model.canRun)

        model.addStep(.clean)
        picker.files = [ToolFile(url: f.dir.file("a.pdf", Pdfs.text()))]
        await model.addFiles()
        XCTAssertFalse(model.canRun)

        picker.folder = try folder(f, "out")
        await model.chooseOutput()
        XCTAssertTrue(model.canRun)
        XCTAssertEqual(model.outputText, f.dir.sub("out").path)
    }

    func test_aFileAddedTwiceIsListedOnce() async throws {
        let f = ViewModelFixture(self)
        let (model, picker) = make(f)
        let file = f.dir.file("a.pdf", Pdfs.text())
        picker.files = [ToolFile(url: file)]

        await model.addFiles()
        await model.addFiles()
        picker.files = [ToolFile(url: URL(fileURLWithPath: file.path.uppercased()))]
        await model.addFiles()

        XCTAssertEqual(model.files.count, 1)
    }

    func test_aFolderAddsItsPdfsInNameOrder() async throws {
        let f = ViewModelFixture(self)
        let (model, picker) = make(f)
        f.dir.file("in/b10.pdf", Pdfs.text())
        f.dir.file("in/b2.PDF", Pdfs.text())
        f.dir.file("in/note.txt", [1])
        picker.folder = ToolFile(url: f.dir.sub("in"))

        await model.addFolder()

        XCTAssertEqual(model.files.map(\.name), ["b2.PDF", "b10.pdf"])
    }

    func test_aRunWritesEachFileLogsItAndDropsTheDoneOnesFromTheList() async throws {
        let f = ViewModelFixture(self)
        let (model, picker) = make(f)
        let good = f.dir.file("a.pdf", Pdfs.text()), bad = f.dir.file("b.pdf", [1, 2, 3])
        picker.files = [ToolFile(url: good), ToolFile(url: bad)]
        picker.folder = try folder(f, "out")
        await model.addFiles()
        await model.chooseOutput()
        model.addStep(.clean)

        await model.run()

        XCTAssertEqual(model.log.count, 2)
        XCTAssertEqual(model.log.map(\.result.ok), [false, true])
        XCTAssertEqual(model.files.map(\.name), ["b.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.dir.sub("out/a.pdf").path))
        XCTAssertEqual(f.vm.statusFull, "1 file failed")
        XCTAssertFalse(model.isRunning)
    }

    func test_aRunOfGoodFilesSaysAllDone() async throws {
        let f = ViewModelFixture(self)
        let (model, picker) = make(f)
        picker.files = [ToolFile(url: f.dir.file("a.pdf", Pdfs.text()))]
        picker.folder = try folder(f, "out")
        await model.addFiles()
        await model.chooseOutput()
        model.addStep(.clean)

        await model.run()

        XCTAssertEqual(f.vm.statusFull, "All files done")
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertEqual(model.log.first?.result.title, "Done")
    }

    func test_batesNumbersGoOnThroughTheFilesOfARunAndIntoTheSavedSet() async throws {
        let f = ViewModelFixture(self)
        let (model, picker) = make(f)
        picker.files = [ToolFile(url: f.dir.file("one.pdf", Pdfs.text(3))), ToolFile(url: f.dir.file("two.pdf", Pdfs.text(2)))]
        picker.folder = try folder(f, "out")
        await model.addFiles()
        await model.chooseOutput()
        model.addStep(.bates)
        model.update { $0.start = 10 }
        model.setName = "Cases"
        model.saveSet()

        await model.run()

        XCTAssertEqual(model.set.steps[0].start, 15)
        XCTAssertEqual(BatchSetStore(directory: f.dir.sub("settings")).load().first?.steps[0].start, 15)
    }

    func test_aSavedSetComesBackWithItsStepsAndItsFolders() async throws {
        let f = ViewModelFixture(self)
        let bookmarks = PathBookmarks()
        let (model, picker) = make(f, bookmarks: bookmarks)
        picker.folder = try folder(f, "out")
        await model.chooseOutput()
        model.addStep(.watermark)
        model.update { $0.text = "DRAFT" }
        model.set.nameTemplate = "{name}-b"
        model.setName = "Cases"
        model.saveSet()
        XCTAssertEqual(model.savedNames, ["Cases"])
        XCTAssertTrue(model.canDeleteSet)

        let (again, _) = make(f, bookmarks: bookmarks)
        XCTAssertEqual(again.savedNames, ["Cases"])
        again.loadSet("Cases")

        XCTAssertEqual(again.set.steps.map(\.text), ["DRAFT"])
        XCTAssertEqual(again.set.nameTemplate, "{name}-b")
        XCTAssertEqual(again.outputFolder?.url.path, f.dir.sub("out").path)
        XCTAssertNil(again.folderNote)
        XCTAssertEqual(bookmarks.grants.count, 1)
    }

    func test_aSetWhoseFoldersCannotBeReachedAgainSaysSoAndCannotRun() async throws {
        let f = ViewModelFixture(self)
        let bookmarks = PathBookmarks()
        let (model, picker) = make(f, bookmarks: bookmarks)
        picker.folder = try folder(f, "out")
        await model.chooseOutput()
        model.addStep(.clean)
        model.setName = "Cases"
        model.saveSet()
        bookmarks.lost = true

        let (again, _) = make(f, bookmarks: bookmarks)
        again.loadSet("Cases")

        XCTAssertNil(again.outputFolder)
        XCTAssertEqual(again.outputText, f.dir.sub("out").path)
        XCTAssertNotNil(again.folderNote)
        XCTAssertFalse(again.canRun)
    }

    func test_aSetNeedsANameAndCanBeDeleted() {
        let f = ViewModelFixture(self)
        let (model, _) = make(f)

        model.setName = "  "
        model.saveSet()
        XCTAssertEqual(f.vm.message?.title, "Set has no name")

        model.setName = "Cases"
        model.saveSet()
        XCTAssertEqual(f.vm.statusFull, "Saved Cases")
        model.deleteSet()
        XCTAssertEqual(f.vm.statusFull, "Deleted Cases")
        XCTAssertTrue(model.savedNames.isEmpty)
        XCTAssertEqual(model.setName, "")
    }

    func test_theLogCanBeCleared() async throws {
        let f = ViewModelFixture(self)
        let (model, picker) = make(f)
        picker.files = [ToolFile(url: f.dir.file("a.pdf", Pdfs.text()))]
        picker.folder = try folder(f, "out")
        await model.addFiles()
        await model.chooseOutput()
        model.addStep(.clean)
        await model.run()
        XCTAssertFalse(model.log.isEmpty)

        model.clearLog()

        XCTAssertTrue(model.log.isEmpty)
    }

    func test_watchingNeedsStepsAFolderThatIsThereAndAnotherResultsFolder() async throws {
        let f = ViewModelFixture(self)
        let log = WatchLog()
        let (model, picker) = make(f, watch: log)
        XCTAssertTrue(model.canWatch)

        model.setWatching(true)
        XCTAssertEqual(f.vm.message?.title, "No steps")
        model.addStep(.clean)
        model.setWatching(true)
        XCTAssertEqual(f.vm.message?.title, "No folder to watch")
        picker.folder = try folder(f, "in")
        await model.chooseWatch()
        model.setWatching(true)
        XCTAssertEqual(f.vm.message?.title, "No results folder")
        await model.chooseOutput()
        model.setWatching(true)
        XCTAssertEqual(f.vm.message?.title, "Same folder")
        XCTAssertFalse(model.isWatching)

        picker.folder = try folder(f, "out")
        await model.chooseOutput()
        model.setWatching(true)

        XCTAssertTrue(model.isWatching)
        XCTAssertEqual(log.folders.map(\.path), [f.dir.sub("in").path])
        XCTAssertEqual(model.watchNote, "Watching \(f.dir.sub("in").path).")
    }

    func test_aFileThatArrivesIsRunAndLoggedAndTheNumbersCountOn() async throws {
        let f = ViewModelFixture(self)
        let log = WatchLog()
        let (model, picker) = make(f, watch: log)
        picker.folder = try folder(f, "in")
        await model.chooseWatch()
        picker.folder = try folder(f, "out")
        await model.chooseOutput()
        model.addStep(.clean)
        model.set.nameTemplate = "{name}-{n}"
        model.setWatching(true)

        log.found?(f.dir.file("in/a.pdf", Pdfs.text()))
        await waitUntil { model.log.count == 1 }
        log.found?(f.dir.file("in/b.pdf", Pdfs.text()))
        await waitUntil { model.log.count == 2 }

        XCTAssertEqual(model.log.map(\.result.ok), [true, true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.dir.sub("out/a-1.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.dir.sub("out/b-2.pdf").path))
        XCTAssertEqual(f.vm.statusFull, "Ran b.pdf")
    }

    func test_switchingTheWatchOffStopsItAndNothingMoreIsRun() async throws {
        let f = ViewModelFixture(self)
        let log = WatchLog()
        let (model, picker) = make(f, watch: log)
        picker.folder = try folder(f, "in")
        await model.chooseWatch()
        picker.folder = try folder(f, "out")
        await model.chooseOutput()
        model.addStep(.clean)
        model.setWatching(true)
        let late = f.dir.file("in/late.pdf", Pdfs.text())

        model.setWatching(false)
        log.found?(late)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(log.watch.stops, 1)
        XCTAssertFalse(model.isWatching)
        XCTAssertTrue(model.log.isEmpty)
    }

    func test_aWatchThatFailsIsLoggedAndSwitchedOff() async throws {
        let f = ViewModelFixture(self)
        let log = WatchLog()
        let (model, picker) = make(f, watch: log)
        picker.folder = try folder(f, "in")
        await model.chooseWatch()
        picker.folder = try folder(f, "out")
        await model.chooseOutput()
        model.addStep(.clean)
        model.setWatching(true)

        log.failed?()
        await waitUntil { !model.isWatching }

        XCTAssertEqual(model.log.first?.result.title, "Watching stopped")
        XCTAssertEqual(model.log.first?.result.ok, false)
    }

    func test_aFolderTheSystemRefusesIsAProblemAndWatchingStaysOff() async throws {
        let f = ViewModelFixture(self)
        let log = WatchLog()
        log.refuses = true
        let (model, picker) = make(f, watch: log)
        picker.folder = try folder(f, "in")
        await model.chooseWatch()
        picker.folder = try folder(f, "out")
        await model.chooseOutput()
        model.addStep(.clean)

        model.setWatching(true)

        XCTAssertFalse(model.isWatching)
        XCTAssertEqual(f.vm.message?.title, "Folder cannot be watched")
    }

    func test_removingTheLastStepWhileWatchingStopsTheWatch() async throws {
        let f = ViewModelFixture(self)
        let log = WatchLog()
        let (model, picker) = make(f, watch: log)
        picker.folder = try folder(f, "in")
        await model.chooseWatch()
        picker.folder = try folder(f, "out")
        await model.chooseOutput()
        model.addStep(.clean)
        model.setWatching(true)

        model.removeSelected()

        XCTAssertFalse(model.isWatching)
        XCTAssertEqual(f.vm.message?.title, "No steps")
        XCTAssertEqual(log.watch.stops, 1)
    }

    func test_choosingAnotherFolderToWatchFollowsIt() async throws {
        let f = ViewModelFixture(self)
        let log = WatchLog()
        let (model, picker) = make(f, watch: log)
        picker.folder = try folder(f, "in")
        await model.chooseWatch()
        picker.folder = try folder(f, "out")
        await model.chooseOutput()
        model.addStep(.clean)
        model.setWatching(true)

        picker.folder = try folder(f, "other")
        await model.chooseWatch()

        XCTAssertTrue(model.isWatching)
        XCTAssertEqual(log.folders.map(\.lastPathComponent), ["in", "other"])
        XCTAssertEqual(log.watch.stops, 1)
    }

    func test_aPlatformWithoutAWatcherDoesNotOfferTheWatch() {
        let f = ViewModelFixture(self)
        let (model, _) = make(f)

        XCTAssertFalse(model.canWatch)
    }

    func test_theSheetHostKeepsItsMessagesAndItsBusyBarForTheSheet() async throws {
        let f = ViewModelFixture(self)
        let host = BatchSheetHost(window: f.vm)
        var during = false

        try await host.runBusy("Working") { token in
            during = host.isBusy && host.busyText == "Working"
            host.showProblem(Problem("Title", "Text"))
            host.cancel()
            XCTAssertTrue(token.isCancelled)
            throw CancellationError()
        }

        XCTAssertTrue(during)
        XCTAssertFalse(host.isBusy)
        XCTAssertEqual(host.status, "Cancelled.")
        XCTAssertEqual(host.message, BatchSheetHost.Message(title: "Title", text: "Text"))
        XCTAssertNil(f.vm.message)
    }

    func test_theStripPanelRunsTheSameModelAndKeepsItsHostWhenItLeaves() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = try XCTUnwrap(f.vm.activeDocument)
        let panel = BatchPanelModel(settings: f.dir.sub("settings"), watcher: nil, runner: { [self] in runner() })
        panel.attach(tab, PanelViewer(tab), f.vm)
        XCTAssertFalse(panel.action!.canRun())
        XCTAssertEqual(panel.action?.text, "Run on every file")

        panel.detach()

        XCTAssertNotNil(panel.batch.host)
    }
}
