#if os(macOS)
import AppKit
import LazyPDFApp
import LazyPDFKit
import LazyPDFUI

// The Mac's counterpart of MainWindow.xaml.cs and App.xaml.cs: the one AppViewModel with the system's services, the file
// panels and the printing it asks for, and the way files and addresses reach it.

@MainActor
final class MacShell {
    static let shared = MacShell()

    let vm: AppViewModel
    let viewer: ViewerModel
    let folders: AppFolders
    private(set) var commands = ShellCommands()
    private weak var window: NSWindow?
    private var closeGuard: CloseGuard?
    private var terminateAnswer = false

    private init() {
        let folders = DefaultAppFolders()
        let sisters = MacSisterApps()
        let vm = AppViewModel(renderers: { PdfKitRenderer() }, codec: ImageIOCodec(), fonts: CoreTextFontSource(), sisters: sisters,
                              certificates: MacCertificates(), bookmarks: MacBookmarks(), folders: folders)
        sisters.printFailed = { [weak vm] in vm?.lazyPrintFailed($0) }
        self.vm = vm
        self.folders = folders
        viewer = ViewerModel(makeRenderer: { PdfKitRenderer() }, openAddress: { NSWorkspace.shared.open($0) })
        vm.exitRequested = { [unowned self] in self.finishExit() }
        commands = ShellCommands(open: { [unowned self] in self.openWithPanel() },
                                 saveAs: { [unowned self] in self.saveAs($0) },
                                 saveCompact: { [unowned self] in self.saveCompact($0) },
                                 print: { [unowned self] in self.systemPrint($0) },
                                 openFiles: { [unowned self] in self.open($0) })
        openTestFile()
    }

    func attach(_ window: NSWindow) {
        if self.window === window { return }
        self.window = window
        let guarded = CloseGuard(original: window.delegate) { [unowned self] in
            MainActor.assumeIsolated { self.vm.requestExit() }
        }
        closeGuard = guarded
        window.delegate = guarded
    }

    // Files

    /// Opens each file with the access its url carries; a url from a panel, a drop or Open With needs none of its own.
    func open(_ urls: [URL]) {
        Task {
            for url in urls { await vm.open(url, access: SecurityScopedAccess.start(url)) }
        }
    }

    private func openWithPanel() {
        open(MacFilePanels.open())
    }

    /// Finder, the Dock and other programs: files, and lazypdf: addresses.
    func handle(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        open(urls.filter(\.isFileURL))
        for url in urls where !url.isFileURL && LazyPdfAddress.isAddress(url.absoluteString) {
            let files = Self.split(url.absoluteString)
            open(files.readable)
            if !files.refused.isEmpty {
                let names = files.refused.map(\.lastPathComponent).joined(separator: ", ")
                vm.showNotice(L10n.t("Not opened"),
                              L10n.t("{0} was not handed over by the program that sent it, so Lazy PDF cannot read it. Open it from the File menu, or drop it on the window.", names))
            }
        }
    }

    /// The files an address names, by whether the sandbox lets the app read a bare path to them.
    nonisolated static func split(_ address: String) -> (readable: [URL], refused: [URL]) {
        let files = LazyPdfAddress.parse(address)
        let readable = files.filter { FileManager.default.isReadableFile(atPath: $0.path) }
        return (readable, files.filter { !readable.contains($0) })
    }

    private func saveAs(_ tab: DocumentTab) -> Bool {
        guard let url = MacFilePanels.save(L10n.t("Save as"), name: tab.title, folder: tab.url?.deletingLastPathComponent()) else { return false }
        return vm.saveAs(tab, url)
    }

    private func saveCompact(_ tab: DocumentTab) {
        guard let url = MacFilePanels.save(L10n.t("Save compact"), name: tab.title, folder: tab.url?.deletingLastPathComponent()) else { return }
        vm.saveCompact(tab, url)
    }

    private func systemPrint(_ tab: DocumentTab) {
        guard tab.canDraw, let operation = MacSystemPrint.operation(tab.session, password: tab.password, title: tab.title) else {
            vm.showProblem(Problem(L10n.t("Not printed"),
                                   L10n.t("{0} could not be prepared for printing. Save it and print it from another program.", tab.title)))
            return
        }
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    // Quitting

    func terminateReply() -> NSApplication.TerminateReply {
        if vm.requestExit() { return .terminateNow }
        // A job that is still running answers with a notice and no question; quitting waits for the person to try again.
        if vm.closeQuestion == nil { return .terminateCancel }
        terminateAnswer = true
        NSApp.activate(ignoringOtherApps: true)
        return .terminateLater
    }

    private func finishExit() {
        if terminateAnswer {
            terminateAnswer = false
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Quit was waiting on the close question and the person answered Cancel.
    func closeQuestionChanged() {
        guard terminateAnswer, vm.closeQuestion == nil else { return }
        terminateAnswer = false
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    // The UI tests cannot hand the sandboxed app a path it may read, so the file comes in the arguments and is written to
    // the app's own temporary folder first: -LazyPDFTestFile name.pdf -LazyPDFTestData <base64>.
    private func openTestFile() {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: "LazyPDFTestFile"), let text = defaults.string(forKey: "LazyPDFTestData"),
              let data = Data(base64Encoded: text) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        if (try? data.write(to: url)) != nil { open([url]) }
    }
}
#endif
