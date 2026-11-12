#if os(iOS)
import SwiftUI
import UIKit
import LazyPDFKit
import LazyPDFApp
import LazyPDFUI

// Follows windows/LazyPDF.App/MainWindow.xaml.cs and MainWindow.Files.cs on the iPhone and iPad: owns the window's model, the
// viewers of the open tabs and the system sheets the window asks for (pickers, share sheet).

struct SheetRequest: Identifiable {
    enum Kind {
        case open
        case export(URL)
        case share(URL)
        case create
        case batch
    }

    let id = UUID()
    let kind: Kind
}

@MainActor
@Observable
final class IOSShell {
    let vm: AppViewModel
    let folders: IOSAppFolders
    let panels: ToolPanels
    var sheet: SheetRequest?

    private let certificates: IOSCertificates
    @ObservationIgnored private var viewers: [UUID: ViewerModel] = [:]
    @ObservationIgnored private var picking: CheckedContinuation<[PickedFile], Never>?
    @ObservationIgnored private var chosen: [PickedFile] = []
    @ObservationIgnored private var waiting: [URL] = []
    @ObservationIgnored private var shownTab: DocumentTab?
    @ObservationIgnored private var shownViewer: ViewerModel?

    init() {
        let keys = IOSCertificates()
        let folders = IOSAppFolders()
        certificates = keys
        self.folders = folders
        let model = AppViewModel(renderers: { PdfKitRenderer() }, codec: ImageIOCodec(), fonts: CoreTextFontSource(),
                                 sisters: IOSSisterApps(), certificates: keys, bookmarks: IOSBookmarks(), folders: folders)
        let panels = ToolPanels(host: model, folders: folders)
        vm = model
        self.panels = panels
        model.handInTyping = { panels.handIn() }
        model.fileWriter = CoordinatedFileWriter()
        model.fileReader = CoordinatedFileReader.read
        let services = IOSToolServices()
        model.filePicker = services
        model.fileExporter = services
        model.clipboard = services
        model.backgroundWork = { name, expired in
            nonisolated(unsafe) var task = UIBackgroundTaskIdentifier.invalid
            nonisolated(unsafe) let end = {
                if task == .invalid { return }
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
            task = UIApplication.shared.beginBackgroundTask(withName: name) {
                MainActor.assumeIsolated {
                    model.flushRecovery()
                    expired()
                    end()
                }
            }
            return end
        }
        // There is no exit to clean up at: what a kill left behind, copies of attachments among it, goes at launch.
        try? FileManager.default.removeItem(at: Self.staging)
        AttachmentsModel.deleteOpenedCopies(in: folders.openedAttachments)
        Exporter.deleteLeftovers()
    }

    var commands: ShellCommands {
        ShellCommands(open: { [self] in
            Task { await openPicked() }
        }, create: { [self] in
            sheet = SheetRequest(kind: .create)
        }, batch: { [self] in
            sheet = SheetRequest(kind: .batch)
        }, saveAs: { [self] tab in
            await saveAs(tab, compact: false)
        }, saveCompact: { [self] tab in
            Task { _ = await saveAs(tab, compact: true) }
        }, print: { [vm] tab in
            IOSSystemPrint.present(tab.session, name: tab.title, problem: vm.showProblem)
        }, share: { [self] tab in
            share(tab)
        }, importCertificate: { [self] in
            await IOSCertificateImport.run(certificates, problem: vm.showProblem)
        }, openFiles: { [self] urls in
            for url in urls { receive(url) }
        })
    }

    func viewer(for tab: DocumentTab) -> ViewerModel {
        if let found = viewers[tab.id] { return found }
        let made = ViewerModel(makeRenderer: { PdfKitRenderer() }, openAddress: { UIApplication.shared.open($0) })
        made.markRequested = { [weak self] in self?.vm.markSelection($0) }
        viewers[tab.id] = made
        return made
    }

    // The viewer of the active tab is shown from here, not from the stage view, which the window rebuilds when it changes
    // between the phone and tablet layouts.
    func showActive() {
        let tab = vm.activeDocument
        guard tab !== shownTab else { return }
        shownViewer?.show(nil)
        shownViewer = tab.map(viewer(for:))
        // The tool panel may have shown it first, and showing again would clear the marks it drew.
        if shownViewer?.tab !== tab { shownViewer?.show(tab) }
        shownTab = tab
    }

    func trimViewers() {
        for viewer in viewers.values { viewer.trimMemory() }
    }

    func dropClosedViewers() {
        let open = Set(vm.documents.map(\.id))
        viewers = viewers.filter { open.contains($0.key) }
    }

    // Files from Files, Mail or another app's Open In come with a grant the app can hold. The address names files by path,
    // which the app cannot read and must not open on a caller's say-so, so the file has to come through the system.
    func receive(_ url: URL) {
        if sheet != nil {
            waiting.append(url)
        } else if url.isFileURL {
            let access = SecurityScopedAccess.start(url)
            Task { await vm.openOrHold(url, access: access, asCopy: Self.isTemporary(url)) }
        } else if !LazyPdfAddress.parse(url.absoluteString).isEmpty {
            vm.showNotice(L10n.t("File not opened"), L10n.t("An address cannot open a file here. Share the file to Lazy PDF or open it from Files."))
        }
    }

    // Mail's Open In and drags from other apps can arrive as a copy in the app's own folders, which saving would change instead
    // of the original.
    static func isTemporary(_ url: URL) -> Bool {
        // The same folder can be named /var/... or /private/var/..., so every side is resolved first.
        let path = url.resolvingSymlinksInPath().path
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox")
        return path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
            || path.hasPrefix(inbox.resolvingSymlinksInPath().path + "/")
    }

    // A hidden launch argument for the UI tests, `-uitestOpen <path>`, honoured in the simulator only.
    func openLaunchFixture() async {
        #if targetEnvironment(simulator)
        guard let path = UserDefaults.standard.string(forKey: "uitestOpen") else { return }
        await vm.open(URL(fileURLWithPath: path))
        #endif
    }

    // The caller of a picker goes on once its sheet is gone, so what it opens can show its own sheets (a password) at once.
    func finishPicking(_ files: [PickedFile]) {
        chosen = files
        sheet = nil
    }

    func sheetClosed() {
        guard sheet == nil else { return }
        let files = chosen
        chosen = []
        picking?.resume(returning: files)
        picking = nil
        let urls = waiting
        waiting = []
        for url in urls { receive(url) }
    }

    private func pick(_ kind: SheetRequest.Kind) async -> [PickedFile] {
        picking?.resume(returning: [])
        picking = nil
        chosen = []
        return await withCheckedContinuation { continuation in
            picking = continuation
            sheet = SheetRequest(kind: kind)
        }
    }

    private func openPicked() async {
        for file in await pick(.open) {
            await vm.open(file.url, access: file.access)
        }
    }

    // The picker copies a placeholder to the place the person names; the tab then saves there itself, through the
    // coordinated writer, so its state and its grant follow the new file. The placeholder is the session's bytes and not a
    // rewritten copy: a file with a password must not reach a synced folder unlocked, even for a moment. A name that is
    // another tab's file is checked only after the copy, so that file is put back as it was.
    private func saveAs(_ tab: DocumentTab, compact: Bool) async -> Bool {
        let name = (tab.title as NSString).deletingPathExtension + ".pdf"
        guard let staged = stage(tab, name: name) else { return false }
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        var backups: [UUID: URL] = [:]
        var unprotected: Set<UUID> = []
        var unchanged: Set<UUID> = []
        for other in vm.documents where other !== tab {
            guard let url = other.url else { continue }
            let backup = staged.deletingLastPathComponent().appendingPathComponent(other.id.uuidString)
            if !other.changedOnDisk { unchanged.insert(other.id) }
            do {
                try CoordinatedFileReader.read(url).write(to: backup)
                backups[other.id] = backup
            } catch {
                unprotected.insert(other.id)
            }
        }
        guard let file = await pick(.export(staged)).first else { return false }
        if let other = vm.tab(of: file.url), other !== tab {
            var restored = false
            if let backup = backups[other.id] {
                do {
                    try CoordinatedFileWriter().write(to: file.url) { try Data(contentsOf: backup).write(to: $0) }
                    // A file another program changed keeps its notice.
                    if unchanged.contains(other.id) { other.acceptDiskState() }
                    restored = true
                } catch {}
            }
            if !restored {
                file.access?.stop()
                vm.showProblem(Problem(L10n.t("Not saved"),
                    L10n.t("{0} is open in another tab and the name you picked replaced it. Go to that tab and save it to put it back.", other.title)))
                return false
            }
        }
        let saved = compact ? vm.saveCompact(tab, file.url) : vm.saveAs(tab, file.url)
        if saved {
            tab.take(file.access)
        } else {
            file.access?.stop()
        }
        return saved
    }

    private func share(_ tab: DocumentTab) {
        let name = tab.title.lowercased().hasSuffix(".pdf") ? tab.title : tab.title + ".pdf"
        guard let file = stage(tab, name: name) else { return }
        sheet = SheetRequest(kind: .share(file))
    }

    private static var staging: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Staging", isDirectory: true)
    }

    private func stage(_ tab: DocumentTab, name: String) -> URL? {
        let folder = Self.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(tab.session.current).write(to: file)
            return file
        } catch {
            vm.showProblem(Problems.save(error, tab.title))
            return nil
        }
    }
}
#endif
