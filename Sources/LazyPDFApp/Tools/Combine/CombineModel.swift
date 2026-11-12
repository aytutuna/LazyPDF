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

    /// The files dropped on the panel: the PDFs are added, and the others are said to be left out once the PDFs have all opened.
    public func drop(_ files: [ToolFile]) async {
        let pdfs = files.filter { $0.url.pathExtension.lowercased() == "pdf" }
        var other = 0
        for file in files where !pdfs.contains(where: { $0.url == file.url }) {
            if (try? file.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            file.access?.stop()
            other += 1
        }
        let all = await add(pdfs)
        if all && other > 0 {
            host?.showNotice(L10n.t("Not a PDF"),
                             L10n.plural(other, one: "{0} dropped file is not a PDF and was left out.", other: "{0} dropped files are not PDFs and were left out."), nil)
        }
    }

    /// False when a file could not be opened; its problem is already on screen.
    @discardableResult
    public func add(_ files: [ToolFile]) async -> Bool {
        guard let host, let tab else { return false }
        var all = true
        for file in files {
            let name = file.url.lastPathComponent
            let path = file.url.standardizedFileURL.path
            // A file listed again shares the first copy, so merge sees one document and carries its attachments once.
            let shared = (lists[tab.id]?.entries ?? []).first { $0.path == path }?.document
            let opened = if let shared { shared } else { await SourceFile.open(host, file, asker) }
            guard let document = opened else {
                all = false
                continue
            }
            if tab.isDisposed { return false }
            let entry = CombineEntry(name, document.pages.count, document, path: path)
            let list = (lists[tab.id]?.entries ?? []) + [entry]
            lists[tab.id] = Held(tab: tab, entries: list)
            if self.tab === tab { entries = list }
        }
        return all
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
        let names = entries.map(\.name)
        var made: [UInt8]?
        var skipped = 0, dropped = 0
        do {
            try await host.runBusy(L10n.t("Combining files")) { token in
                (made, skipped, dropped) = try await ToolDocuments.run(token) { () throws -> ([UInt8], Int, Int) in
                    // A job that was cancelled may still be reading the same documents; this one waits for it.
                    gate.lock()
                    defer { gate.unlock() }
                    try token.throwIfCancelled()
                    // The open document is read again here: its pages may be taken twice and the session belongs to the main actor.
                    let again = try copy.open()
                    let merged = try PageAssembly.merge(ordered.map { MergeSource($0.document ?? again, $0.pages) }, titles: ordered.map(\.title))
                    let bytes = try merged.saveRewrite()
                    try token.throwIfCancelled()
                    return (bytes, merged.skippedAttachments, merged.droppedObjects)
                }
            }
        } catch {
            // Each file alone, in order, to name the first one the merge cannot take.
            var bad: String?
            var checked = false
            do {
                try await host.runBusy(L10n.t("Checking the files")) { token in
                    bad = try await ToolDocuments.run(token) { () throws -> String? in
                        gate.lock()
                        defer { gate.unlock() }
                        let again = try copy.open()
                        for (name, source) in zip(names, ordered) {
                            try token.throwIfCancelled()
                            do {
                                _ = try PageAssembly.merge([MergeSource(source.document ?? again, source.pages)]).saveRewrite()
                            } catch is PdfReadException {
                                return name
                            } catch is ArgumentException {
                                return name
                            }
                        }
                        return nil
                    }
                    checked = true
                }
            } catch {
                checked = true
            }
            if !checked { return }
            host.showProblem(Problem(L10n.t("Files not combined"), bad.map { L10n.t("{0} could not be put into the file. Leave it out, or try fewer of its pages.", $0) }
                ?? L10n.t("The files could not be put into one. Try fewer pages or files.")))
            return
        }
        guard let bytes = made else { return }

        let name = L10n.t("Combined.pdf")
        let protectedSource = documents.contains { $0.isEncrypted }
        let left = PageJobs.leftOutText(skipped, dropped)
        if toFolder {
            await save(host, [(name, bytes)], protectedSource, left)
            return
        }
        await host.openNew(bytes, title: name, password: nil, certificate: nil)
        if protectedSource { host.showNotice(L10n.t("Copy is not protected"), (CopyRules.unprotected + " " + left).trimmingCharacters(in: .whitespaces), nil) }
        else { PageJobs.noteLeftOut(host, skipped, dropped) }
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
        var skipped = 0, dropped = 0
        do {
            try await host.runBusy(L10n.t("Splitting file")) { token in
                (made, skipped, dropped) = try await ToolDocuments.run(token) { () throws -> ([[UInt8]], Int, Int) in
                    var saved: [[UInt8]] = []
                    var left = 0, damaged = 0
                    for part in try CombineJob.split(copy.open(), kind, perPart, token) {
                        try token.throwIfCancelled()
                        saved.append(try part.saveRewrite())
                        left += part.skippedAttachments
                        damaged += part.droppedObjects
                    }
                    return (saved, left, damaged)
                }
            }
        } catch {
            host.showProblem(Problem(L10n.t("File not split"), L10n.t("The parts could not be made. Try a different amount.")))
            return
        }
        guard let parts = made else { return }
        if parts.count < 2 {
            host.showNotice(L10n.t("Nothing to split"), L10n.t("The whole file fits in one part. Use a smaller amount."), nil)
            return
        }

        var big = ""
        if kind == .size {
            let over = CombineJob.partsOver(parts, Int(perPart * Double(CombineJob.megabyteBytes)))
            if over > 0 {
                big = L10n.plural(over, one: "{0} part is bigger than {1} MB. A single page is too large to fit.",
                                  other: "{0} parts are bigger than {1} MB. A single page is too large to fit.", amount.trimmingCharacters(in: .whitespaces))
            }
        }

        big = (big + " " + PageJobs.leftOutText(skipped, dropped)).trimmingCharacters(in: .whitespaces)

        let stem = (tab.title as NSString).deletingPathExtension
        let named = parts.enumerated().map { (name: CombineJob.partName(stem, $0.offset, parts.count), bytes: $0.element) }
        var saveThem = toFolder
        if !saveThem && parts.count > Self.mostTabs {
            host.showNotice(L10n.t("Too many parts for tabs"), L10n.t("Pick a folder for the parts."), nil)
            saveThem = true
        }
        if saveThem {
            await save(host, named, tab.document.isEncrypted, big)
            return
        }
        for part in named { await host.openNew(part.bytes, title: part.name, password: nil, certificate: nil) }
        host.setStatus(([L10n.t("{0} parts opened.", parts.count), big]).filter { !$0.isEmpty }.joined(separator: " "))
        CopyRules.noteUnprotected(tab.document, host)
    }

    // The files are written to a folder of the app's own and handed to the exporter, which asks where they go.
    private func save(_ host: ToolHost, _ files: [(name: String, bytes: [UInt8])], _ protectedSource: Bool, _ extra: String) async {
        let folder = Exporter.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        var text = protectedSource ? place + ". " + CopyRules.unprotected : place
        if !extra.isEmpty { text += ". " + extra }
        host.showNotice(L10n.plural(saved.count, one: "{0} file saved", other: "{0} files saved"), text,
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
