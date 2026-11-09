import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Batch/BatchPanel.xaml.cs and BatchPanel.Steps.cs: the same steps over many files, a list of
// steps with their settings, the files or a watched folder to run them on, a log of what happened to each, and sets that are kept
// by name. It is not tied to a document, so the Home tile presents it in a sheet and the tool strip shows it beside the document in
// view. The results folder, the watched folder and the files are security-scoped grants held while they are listed; a saved set
// takes them again through its bookmarks. BatchModel+Run has the run and the watch.

public struct BatchStepRow: Identifiable, Equatable {
    public let index: Int
    public let step: BatchStep
    public var id: Int { index }
    public var title: String { BatchText.title(step.kind) }
    public var detail: String { BatchText.detail(step) }
    public var spoken: String { "\(title), \(detail)" }
}

public struct BatchFile: Identifiable {
    public let id = UUID()
    public let url: URL
    let access: FileAccess?

    public var name: String { url.lastPathComponent }
    public var removeName: String { L10n.t("Remove {0}", name) }
}

public struct BatchLogRow: Identifiable {
    public let id = UUID()
    public let result: BatchResult

    public var name: String { result.input.lastPathComponent }
    public var spoken: String { "\(name), \(result.title). \(result.detail)" }
}

@MainActor
@Observable
public final class BatchModel {
    public var set = BatchSet()
    public var setName = ""
    public private(set) var savedNames: [String] = []
    public var selected: Int?
    public private(set) var files: [BatchFile] = []
    public private(set) var log: [BatchLogRow] = []
    public private(set) var outputFolder: ToolFile?
    public private(set) var watchFolder: ToolFile?
    public internal(set) var isRunning = false
    public internal(set) var isWatching = false

    var host: ToolHost?

    /// The window of the sheet, which says what happens in the sheet itself; nil for the panel of the tool strip.
    public private(set) var sheetHost: BatchSheetHost?
    let store: BatchSetStore
    var bookmarks: Bookmarks?
    let makeRunner: () -> BatchRunner
    let watcherFactory: FolderWatchFactory?
    @ObservationIgnored var runner: BatchRunner?
    @ObservationIgnored var watcher: FolderWatching?
    @ObservationIgnored var watchCancel: CancelToken?
    @ObservationIgnored var watchGeneration = 0
    @ObservationIgnored var watchedFolder: URL?
    @ObservationIgnored var arrived: [URL] = []
    @ObservationIgnored var draining = false
    @ObservationIgnored var watched = 0
    @ObservationIgnored let gate = RunGate()
    @ObservationIgnored private var languages: OcrLanguageState?

    /// `watcherFactory` is nil where the platform cannot watch a folder, and then the watch is not offered.
    public init(host: ToolHost?, settings: URL, bookmarks: Bookmarks?, watcher: FolderWatchFactory?, runner makeRunner: @escaping () -> BatchRunner) {
        self.host = host
        store = BatchSetStore(directory: settings)
        self.bookmarks = bookmarks
        self.makeRunner = makeRunner
        watcherFactory = watcher
        savedNames = store.load().map(\.name)
    }

    /// The model for the sheet of the Home tile: it reports in the sheet, and opens files and asks for folders through `window`.
    public static func sheet(window: AppViewModel, settings: URL, watcher: FolderWatchFactory?, runner: @escaping () -> BatchRunner) -> BatchModel {
        let host = BatchSheetHost(window: window)
        let model = BatchModel(host: host, settings: settings, bookmarks: window.bookmarks, watcher: watcher, runner: runner)
        model.sheetHost = host
        return model
    }

    public var canWatch: Bool { watcherFactory != nil }

    public var canRun: Bool { !files.isEmpty && !set.steps.isEmpty && outputFolder != nil && !isRunning }

    public var summary: String { ToolCatalog.find("batch")?.summary ?? "" }

    public var templateHint: String { L10n.t("Use {0}, {1} and {2}. A name that is taken gets a number.", "{name}", "{n}", "{date}") }

    public var rows: [BatchStepRow] {
        set.steps.enumerated().map { BatchStepRow(index: $0.offset, step: $0.element) }
    }

    public var step: BatchStep? {
        guard let selected, set.steps.indices.contains(selected) else { return nil }
        return set.steps[selected]
    }

    public var canMoveUp: Bool { (selected ?? 0) > 0 }
    public var canMoveDown: Bool { selected.map { $0 < set.steps.count - 1 } ?? false }
    public var canDeleteSet: Bool { savedNames.contains(setName) }

    public var outputText: String { outputFolder?.url.path ?? set.outputFolder }
    public var watchText: String { watchFolder?.url.path ?? set.watchFolder }

    /// Said when a saved set names a folder the app cannot get into again until the person chooses it.
    public var folderNote: String? {
        (!set.outputFolder.isEmpty && outputFolder == nil) || (!set.watchFolder.isEmpty && watchFolder == nil)
            ? L10n.t("Choose the folders again. The system gives Lazy PDF access to a folder only when you pick it.") : nil
    }

    public var watchNote: String {
        isWatching ? L10n.t("Watching {0}.", watchedFolder?.path ?? "") : L10n.t("PDFs that appear in the folder are run through the steps.")
    }

    // MARK: Steps

    public func addStep(_ kind: BatchStepKind) {
        set.steps.append(BatchStep.of(kind))
        selected = set.steps.count - 1
    }

    public func moveSelected(_ by: Int) {
        guard let from = selected, set.steps.indices.contains(from + by) else { return }
        set.steps.swapAt(from, from + by)
        selected = from + by
    }

    public func removeSelected() {
        guard let at = selected, set.steps.indices.contains(at) else { return }
        set.steps.remove(at: at)
        selected = nil
        recheckWatch()
    }

    /// Changes the settings of the selected step.
    public func update(_ change: (inout BatchStep) -> Void) {
        guard let at = selected, set.steps.indices.contains(at) else { return }
        change(&set.steps[at])
    }

    // A box that holds something that is not a number keeps the setting it had.
    public func setOpacity(_ text: String) { number(text, 5, 100) { $0.opacity = $1 } }
    public func setAngle(_ text: String) { number(text, -360, 360) { $0.angle = $1 } }
    public func setSize(_ text: String) { number(text, 10, 100) { $0.size = $1 } }
    public func setDigits(_ text: String) { number(text, 1, 18) { $0.digits = $1 } }

    public func setStart(_ text: String) {
        if let start = Int(text.trimmingCharacters(in: .whitespaces)), start >= 0 { update { $0.start = start } }
    }

    private func number(_ text: String, _ low: Int, _ high: Int, _ set: (inout BatchStep, Int) -> Void) {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
        update { set(&$0, min(max(value, low), high)) }
    }

    /// The languages the system recognizes, and the one the step names when the system lacks it, so the step shows what it will
    /// ask for.
    public var languageChoices: [OcrLanguage] {
        var choices = languageState().installed
        if let tag = step?.text, step?.kind == .ocr, !choices.contains(where: { $0.tag.caseInsensitiveCompare(tag) == .orderedSame }) {
            choices.append(OcrLanguage(tag: tag, name: tag))
        }
        return choices
    }

    public var languageAdvice: String { languageState().advice }

    private func languageState() -> OcrLanguageState {
        if let languages { return languages }
        let read = OcrLanguageState.read()
        languages = read
        return read
    }

    // MARK: Sets

    public func loadSet(_ name: String) {
        guard let saved = store.load().first(where: { $0.name == name }) else { return }
        set = saved
        setName = saved.name
        selected = nil
        outputFolder = grant(saved.outputBookmark)
        watchFolder = grant(saved.watchBookmark)
        recheckWatch()
    }

    public func saveSet() {
        let name = setName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            host?.showProblem(Problem(L10n.t("Set has no name"), L10n.t("Type a name for the set, then save it.")))
            return
        }
        set.name = name
        set.outputBookmark = outputFolder.flatMap { bookmarks?.make($0.url) }
        set.watchBookmark = watchFolder.flatMap { bookmarks?.make($0.url) }
        store.save(set)
        savedNames = store.load().map(\.name)
        host?.setStatus(L10n.t("Saved {0}", name))
    }

    public func deleteSet() {
        let name = setName
        store.delete(name)
        setName = ""
        savedNames = store.load().map(\.name)
        host?.setStatus(L10n.t("Deleted {0}", name))
    }

    private func grant(_ bookmark: Data?) -> ToolFile? {
        guard let bookmarks, let bookmark, let resolved = bookmarks.resolve(bookmark) else { return nil }
        return ToolFile(url: resolved.url, access: bookmarks.access(resolved.url))
    }

    // MARK: Files and folders

    public func addFiles() async {
        guard let host else { return }
        add(await host.filePicker.pickFiles([.pdf], multiple: true))
    }

    public func addFolder() async {
        guard let host, let folder = await host.filePicker.pickFolder() else { return }
        let names = ((try? FileManager.default.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        add(names.map { ToolFile(url: $0, access: folder.access) })
    }

    func add(_ picked: [ToolFile]) {
        for file in picked where !files.contains(where: { $0.url.path.caseInsensitiveCompare(file.url.path) == .orderedSame }) {
            files.append(BatchFile(url: file.url, access: file.access))
        }
    }

    public func removeFile(_ id: UUID) {
        files.removeAll { $0.id == id }
    }

    public func clearLog() {
        log = []
    }

    func addLog(_ result: BatchResult) {
        log.insert(BatchLogRow(result: result), at: 0)
    }

    public func chooseOutput() async {
        guard let host, let folder = await host.filePicker.pickFolder() else { return }
        outputFolder = folder
        set.outputFolder = folder.url.path
        recheckWatch()
    }

    public func chooseWatch() async {
        guard let host, let folder = await host.filePicker.pickFolder() else { return }
        watchFolder = folder
        set.watchFolder = folder.url.path
        recheckWatch()
    }
}

/// One file at a time, so a run and the watcher never share the Bates numbers or the output names.
@MainActor
final class RunGate {
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            held = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// The Batch tool of the strip: the same model as the sheet, beside the document in view. A watched folder keeps being served
/// while another tool is open, so detaching leaves the window's host in place.
@MainActor
@Observable
public final class BatchPanelModel: ToolPanelModel {
    public let batch: BatchModel

    public init(settings: URL, watcher: FolderWatchFactory?, runner: @escaping () -> BatchRunner) {
        batch = BatchModel(host: nil, settings: settings, bookmarks: nil, watcher: watcher, runner: runner)
    }

    public var action: ToolAction? {
        ToolAction(L10n.t("Run on every file"), symbol: "play", canRun: { [self] in batch.canRun }, run: { [self] in await batch.run() })
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        batch.host = host
        batch.bookmarks = (host as? AppViewModel)?.bookmarks
    }

    public func detach() {}
}
