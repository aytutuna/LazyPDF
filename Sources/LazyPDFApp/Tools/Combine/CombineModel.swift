import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Combine/CombinePanel.xaml.cs and CombinePanel.Run.cs: puts this file and others into one,
// with the pages and the order the person picks, or cuts this file into parts. The result opens in new tabs, or goes to the place
// the person names for it.

@MainActor
@Observable
public final class CombineModel: ToolPanelModel {
    // Parts open as tabs only up to this many; more than that goes to a folder.
    static let mostTabs = 10

    public let asker = SourceQuestion()
    public private(set) var entries: [CombineEntry] = []
    public private(set) var splitHint = ""
    public private(set) var isSigned = false
    public private(set) var pageCount = 0

    public private(set) var splitting = false

    public private(set) var splitKind = SplitBy.count
    public var amount = "10"

    /// Save the result to files instead of opening it in tabs.
    public var toFolder = false

    // Each document keeps its own list, so a look at another tab does not lose the files that were picked. A list goes with its tab
    // (the ConditionalWeakTable of Windows): the files in it may be decrypted.
    private struct Held {
        weak var tab: DocumentTab?
        var entries: [CombineEntry]
    }

    @ObservationIgnored private var lists: [UUID: Held] = [:]

    // Only one job at a time reads the documents of the entries, whose object caches are not safe to share between threads.
    private let reading = NSLock()
    @ObservationIgnored private var tab: DocumentTab?
    @ObservationIgnored private var host: ToolHost?
    @ObservationIgnored private var watch: ObservationWatch?

    public init() {}

    public var action: ToolAction? {
        if splitting {
            return ToolAction(L10n.t("Split file"), symbol: "scissors",
                              canRun: { [self] in pageCount > 1 && CombineJob.amount(splitKind, amount) != nil }, run: { [self] in await split() })
        }
        return ToolAction(L10n.t("Combine files"), symbol: "doc.on.doc", canRun: { [self] in entries.count > 1 }, run: { [self] in await combine() })
    }

    public var amountLabel: String { splitKind == .size ? L10n.t("Megabytes per part") : L10n.t("Pages per part") }
    public var showsAmount: Bool { splitKind != .bookmarks }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.host = host
        asker.choices = { [weak host] in host?.certificateChoices() ?? [] }
        dropClosedTabs()
        if lists[tab.id] == nil { lists[tab.id] = Held(tab: tab, entries: [CombineEntry(tab.title, tab.pageCount, nil)]) }
        entries = lists[tab.id]?.entries ?? []
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.refresh() })
        refresh()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        asker.giveUp()
        tab = nil
        host = nil
        entries = []
        dropClosedTabs()
    }

    private func dropClosedTabs() {
        lists = lists.filter { held in held.value.tab.map { !$0.isDisposed } ?? false }
    }

    var heldLists: Int { lists.count }

    // The file may have lost or gained pages while another tab was shown.
    private func refresh() {
        guard let tab else { return }
        for entry in entries where entry.document == nil { entry.pages = tab.pageCount }
        pageCount = tab.pageCount
        isSigned = tab.document.isSigned
        if splitKind == .bookmarks {
            let parts = CombineJob.bookmarkParts(tab.document)
            splitHint = L10n.plural(parts, one: "The bookmarks make {0} part.", other: "The bookmarks make {0} parts.")
        } else {
            splitHint = pageCount < 2 ? L10n.t("A file of one page cannot be split.") : ""
        }
    }

    public func setSplitting(_ on: Bool) {
        splitting = on
        refresh()
    }

    public func setKind(_ kind: SplitBy) {
        splitKind = kind
        amount = kind == .size ? "5" : "10"
        refresh()
    }

    private func store(_ list: [CombineEntry]) {
        entries = list
        if let tab { lists[tab.id] = Held(tab: tab, entries: list) }
    }

    public func moveUp(_ entry: CombineEntry) {
        guard let at = entries.firstIndex(where: { $0 === entry }), at > 0 else { return }
        var list = entries
        list.swapAt(at, at - 1)
        store(list)
    }

    public func moveDown(_ entry: CombineEntry) {
        guard let at = entries.firstIndex(where: { $0 === entry }), at < entries.count - 1 else { return }
        var list = entries
        list.swapAt(at, at + 1)
        store(list)
    }

    /// Puts `entry` in the place of `target`, as a drag of one row onto another does.
    public func move(_ entry: CombineEntry, onto target: CombineEntry) {
        guard let from = entries.firstIndex(where: { $0 === entry }), let to = entries.firstIndex(where: { $0 === target }), from != to else { return }
        var list = entries
        list.insert(list.remove(at: from), at: to)
        store(list)
    }

    public func remove(_ entry: CombineEntry) {
        store(entries.filter { $0 !== entry })
    }

    public func addFiles() async {
        guard let host else { return }
        let files = await host.filePicker.pickFiles([.pdf], multiple: true)
        await add(files)
    }

    public func add(_ files: [ToolFile]) async {
        guard let host, let tab else { return }
        for file in files {
            let name = file.url.lastPathComponent
            let path = file.url.standardizedFileURL.path
            // A file listed again shares the first copy, so merge sees one document and carries its attachments once.
            let shared = (lists[tab.id]?.entries ?? []).first { $0.path == path }?.document
            let opened = if let shared { shared } else { await SourceFile.open(host, file, asker) }
            guard let document = opened else { continue }
            if tab.isDisposed { return }
            let entry = CombineEntry(name, document.pages.count, document, path: path)
            let list = (lists[tab.id]?.entries ?? []) + [entry]
            lists[tab.id] = Held(tab: tab, entries: list)
            if self.tab === tab { entries = list }
        }
    }

    func combine() async {
        guard let tab, let host else { return }
        var documents: [PdfDocument] = []
        for entry in entries {
            let document = entry.document ?? tab.document
            if !documents.contains(where: { $0 === document }) { documents.append(document) }
        }
        if documents.contains(where: { CopyRules.refused($0, host) }) { return }

        var sources: [(document: PdfDocument?, pages: [Int]?, title: String)] = []
        for entry in entries {
            if entry.range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sources.append((entry.document, nil, entry.title))
                continue
            }
            let range = PageRange.parse(entry.range, entry.pages)
            if let error = range.error {
                host.showProblem(Problem(L10n.t("Pages not understood"), L10n.t("{0}: {1}", entry.name, error.message)))
                return
            }
            sources.append((entry.document, range.pages, entry.title))
        }

        let copy = TabCopy(tab, host)
        let ordered = sources
        let gate = reading
        var made: [UInt8]?
        var skipped = 0
        do {
            try await host.runBusy(L10n.t("Combining files")) { token in
                (made, skipped) = try await ToolDocuments.run(token) { () throws -> ([UInt8], Int) in
                    // A job that was cancelled may still be reading the same documents; this one waits for it.
                    gate.lock()
                    defer { gate.unlock() }
                    try token.throwIfCancelled()
                    // The open document is read again here: its pages may be taken twice and the session belongs to the main actor.
                    let again = try copy.open()
                    let merged = try PageAssembly.merge(ordered.map { MergeSource($0.document ?? again, $0.pages) }, titles: ordered.map(\.title))
                    let bytes = try merged.saveRewrite()
                    try token.throwIfCancelled()
                    return (bytes, merged.skippedAttachments)
                }
            }
        } catch {
            host.showProblem(Problem(L10n.t("Files not combined"), L10n.t("The files could not be put into one. Try fewer pages or files.")))
            return
        }
        guard let bytes = made else { return }
        PageJobs.noteSkippedAttachments(host, skipped)

        let name = L10n.t("Combined.pdf")
        let protectedSource = documents.contains { $0.isEncrypted }
        if toFolder {
            await save(host, [(name, bytes)], protectedSource)
            return
        }
        await host.openNew(bytes, title: name, password: nil, certificate: nil)
        if protectedSource { host.showNotice(L10n.t("Copy is not protected"), CopyRules.unprotected, nil) }
    }

    func split() async {
        guard let tab, let host, let perPart = CombineJob.amount(splitKind, amount) else { return }
        let kind = splitKind
        if CopyRules.refused(tab.document, host) { return }
        if kind == .bookmarks && CombineJob.bookmarkParts(tab.document) < 2 {
            host.showProblem(Problem(L10n.t("Nothing to cut at"), L10n.t("No bookmark starts after the first page. Split by pages or size instead.")))
            return
        }
        let copy = TabCopy(tab, host)
        var made: [[UInt8]]?
        var skipped = 0
        do {
            try await host.runBusy(L10n.t("Splitting file")) { token in
                (made, skipped) = try await ToolDocuments.run(token) { () throws -> ([[UInt8]], Int) in
                    var saved: [[UInt8]] = []
                    var left = 0
                    for part in try CombineJob.split(copy.open(), kind, perPart, token) {
                        try token.throwIfCancelled()
                        saved.append(try part.saveRewrite())
                        left += part.skippedAttachments
                    }
                    return (saved, left)
                }
            }
        } catch {
            host.showProblem(Problem(L10n.t("File not split"), L10n.t("The parts could not be made. Try a different amount.")))
            return
        }
        guard let parts = made else { return }
        PageJobs.noteSkippedAttachments(host, skipped)
        if parts.count < 2 {
            host.showNotice(L10n.t("Nothing to split"), L10n.t("The whole file fits in one part. Use a smaller amount."), nil)
            return
        }

        let stem = (tab.title as NSString).deletingPathExtension
        let named = parts.enumerated().map { (name: CombineJob.partName(stem, $0.offset, parts.count), bytes: $0.element) }
        var saveThem = toFolder
        if !saveThem && parts.count > Self.mostTabs {
            host.showNotice(L10n.t("Too many parts for tabs"), L10n.t("Pick a folder for the parts."), nil)
            saveThem = true
        }
        if saveThem {
            await save(host, named, tab.document.isEncrypted)
            return
        }
        for part in named { await host.openNew(part.bytes, title: part.name, password: nil, certificate: nil) }
        host.setStatus(L10n.t("{0} parts opened.", parts.count))
        CopyRules.noteUnprotected(tab.document, host)
    }

    // The files are written to a folder of the app's own and handed to the exporter, which asks where they go.
    private func save(_ host: ToolHost, _ files: [(name: String, bytes: [UInt8])], _ protectedSource: Bool) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var written: [URL] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                let path = CombineJob.uniquePath(folder, file.name)
                try Data(file.bytes).write(to: path)
                written.append(path)
            }
        } catch {
            host.showProblem(Problems.save(error, files.first?.name ?? ""))
            return
        }
        let outcome = await host.fileExporter.export(written)
        let saved = outcome.saved
        // A file that could not be written is not the person giving up, and the files that were written still count.
        if let failed = outcome.failed.first {
            host.showProblem(Problems.save(CocoaError(outcome.denied ? .fileWriteNoPermission : .fileWriteUnknown), failed.lastPathComponent))
        }
        guard let first = saved.first else { return }
        let place = first.deletingLastPathComponent().path
        host.showNotice(L10n.plural(saved.count, one: "{0} file saved", other: "{0} files saved"),
                        protectedSource ? place + ". " + CopyRules.unprotected : place,
                        NoticeAction(L10n.t("Open the first")) { Task { await host.open(first, access: Self.grant(first)) } })
    }

    // The exporter has let go of the grant of the saved file, so the tab that opens it asks for its own.
    private static func grant(_ url: URL) -> FileAccess? {
        #if canImport(Darwin)
        return SecurityScopedAccess.start(url)
        #else
        return nil
        #endif
    }
}
