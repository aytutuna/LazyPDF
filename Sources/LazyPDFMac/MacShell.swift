#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
    let panels: ToolPanels
    private let certificates: MacCertificates
    private(set) var commands = ShellCommands()
    private weak var window: NSWindow?
    private var closeGuard: CloseGuard?
    private var terminateAnswer = false
    var noteRecent: (URL) -> Void = { NSDocumentController.shared.noteNewRecentDocumentURL($0) }

    private init() {
        let folders = DefaultAppFolders()
        let sisters = MacSisterApps()
        let certificates = MacCertificates()
        let vm = AppViewModel(renderers: { PdfKitRenderer() }, codec: ImageIOCodec(), fonts: CoreTextFontSource(), sisters: sisters,
                              certificates: certificates, bookmarks: MacBookmarks(), folders: folders)
        sisters.printFailed = { [weak vm] in vm?.lazyPrintFailed($0) }
        self.vm = vm
        self.certificates = certificates
        self.folders = folders
        let panels = ToolPanels(host: vm, folders: folders)
        self.panels = panels
        vm.handInTyping = { panels.handIn() }
        viewer = ViewerModel(makeRenderer: { PdfKitRenderer() }, openAddress: { NSWorkspace.shared.open($0) })
        vm.fileWriter = CoordinatedFileWriter()
        vm.fileReader = CoordinatedFileReader.read
        let services = MacToolServices()
        vm.filePicker = services
        vm.fileExporter = services
        vm.clipboard = services
        AttachmentsModel.deleteOpenedCopies(in: folders.openedAttachments)
        Exporter.deleteLeftovers()
        vm.exitRequested = { [unowned self] in self.finishExit() }
        commands = ShellCommands(open: { [unowned self] in self.openWithPanel() },
                                 create: { [unowned self] in self.present { CreateSheet(host: self.vm, close: $0) } },
                                 batch: { [unowned self] in self.present { BatchSheet(host: self.vm, folders: self.folders, close: $0) } },
                                 saveAs: { [unowned self] in self.saveAs($0) },
                                 saveCompact: { [unowned self] in self.saveCompact($0) },
                                 print: { [unowned self] in self.systemPrint($0) },
                                 share: { [unowned self] in self.share($0) },
                                 importCertificate: { [unowned self] in self.importCertificate() },
                                 openFiles: { [unowned self] in self.open($0) })
        #if LAZYPDF_UITESTS
        openTestFile()
        #endif
    }

    func attach(_ window: NSWindow) {
        self.window = window
        update(WindowState(vm.activeDocument))
        closeGuard = CloseGuard.ensure(on: window, existing: closeGuard, hasTabs: { !self.vm.documents.isEmpty }) { NSApp.terminate(nil) }
    }

    func update(_ state: WindowState) {
        window?.title = state.title
        window?.representedURL = state.url
        window?.isDocumentEdited = state.dirty
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // The sheets of the Create and Batch tiles hang from the window, as a dialog does on Windows.
    private func present<Content: View>(_ content: (@escaping () -> Void) -> Content) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let close = { [weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet)
            sheet.orderOut(nil)
        }
        sheet.contentViewController = NSHostingController(rootView: content(close))
        window.beginSheet(sheet)
    }

    /// Opens each file with the access its url carries; a url from a panel, a drop or Open With needs none of its own.
    func open(_ urls: [URL]) {
        if !urls.isEmpty { showWindow() }
        Task {
            for url in urls {
                await vm.openOrHold(url, access: SecurityScopedAccess.start(url))
                if vm.tab(of: url) != nil { noteRecent(url) }
            }
        }
    }

    private func openWithPanel() {
        open(MacFilePanels.open())
    }

    /// Finder, the Dock and other programs: files, and lazypdf: addresses.
    func handle(_ urls: [URL]) {
        showWindow()
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

    private func importCertificate() -> CertificateChoice? {
        let panel = NSOpenPanel()
        panel.title = L10n.t("Import")
        panel.allowedContentTypes = ["p12", "pfx"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url, let bytes = try? Data(contentsOf: url) else { return nil }
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let alert = NSAlert()
        alert.messageText = L10n.t("Password of the PFX file")
        alert.informativeText = url.lastPathComponent + "\n" + L10n.t("The certificate is added to your keychain so you can use it again.")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("Import"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        do {
            let imported = try certificates.importIdentity([UInt8](bytes), password: field.stringValue)
            if !imported.kept {
                vm.showNotice(L10n.t("Certificate not kept"), L10n.t("The keychain would not keep {0}. You can use it until you quit Lazy PDF.", url.lastPathComponent))
            }
            return imported.choice
        } catch {
            vm.showProblem(Problem(L10n.t("Not imported"), L10n.t("{0} could not be imported. Check the password.", url.lastPathComponent)))
            return nil
        }
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

    private func share(_ tab: DocumentTab) {
        guard let view = window?.contentView else { return }
        let folder = folders.printCopies.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = tab.title.lowercased().hasSuffix(".pdf") ? tab.title : tab.title + ".pdf"
        let file = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(tab.session.current).write(to: file)
        } catch {
            vm.showProblem(Problems.save(error, tab.title))
            return
        }
        NSSharingServicePicker(items: [file]).show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }

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

    #if LAZYPDF_UITESTS
    // The UI tests cannot hand the sandboxed app a path it may read, so the file comes in the arguments and is written to
    // the app's own temporary folder first: -LazyPDFTestFile name.pdf -LazyPDFTestData <base64>. Only the UI-test build
    // compiles it (-DLAZYPDF_UITESTS), so the store binary ignores these arguments.
    private static func argument(_ key: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: key).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    private func openTestFile() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let name = Self.argument("-LazyPDFTestFile", in: arguments), let text = Self.argument("-LazyPDFTestData", in: arguments),
              let data = Data(base64Encoded: text) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        if (try? data.write(to: url)) != nil { open([url]) }
    }
    #endif
}
#endif
