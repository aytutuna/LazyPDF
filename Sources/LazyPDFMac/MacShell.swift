#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LazyPDFApp
import LazyPDFKit
import LazyPDFUI

// The Mac's counterpart of MainWindow.xaml.cs: the AppViewModel of one window with the system's services, the file panels
// and the printing it asks for, and the way files and addresses reach it. Each window has its own; WindowHub holds them.

@MainActor
final class MacShell {
    let id: UUID
    let isPrimary: Bool
    let vm: AppViewModel
    let viewer: ViewerModel
    let folders: AppFolders
    let panels: ToolPanels
    private unowned let hub: WindowHub
    private let certificates: MacCertificates
    private(set) var commands = ShellCommands()
    private(set) weak var window: NSWindow?
    private var closeGuard: CloseGuard?
    private var sheetEnd: NSObjectProtocol?
    /// The red button asked this window to close and a question about its tabs is up.
    var closing = false
    var filesFromOutside = false
    /// The last tab left while the window was busy, so it closes once it is not.
    var closeWhenIdle = false
    /// Where the window goes when it is shown, for one made by dragging a tab out: the tab's end of the drag.
    var placeAt: CGPoint?
    private var restored = false
    private var hadWindow = false
    var noteRecent: (URL) -> Void = { NSDocumentController.shared.noteNewRecentDocumentURL($0) }

    init(hub: WindowHub, id: UUID, primary: Bool) {
        self.hub = hub
        self.id = id
        isPrimary = primary
        let folders = hub.folders
        let sisters = MacSisterApps()
        let certificates = hub.certificates
        let vm = AppViewModel(renderers: { PdfKitRenderer() }, codec: ImageIOCodec(), fonts: CoreTextFontSource(), sisters: sisters,
                              certificates: certificates, bookmarks: MacBookmarks(), folders: folders, recovery: hub.recovery,
                              toolState: hub.toolState, registry: hub.registry)
        vm.offersRecovery = primary
        sisters.printFailed = { [weak vm] in vm?.lazyPrintFailed($0) }
        self.vm = vm
        self.certificates = certificates
        self.folders = folders
        let panels = ToolPanels(host: vm, folders: folders, state: hub.toolState)
        self.panels = panels
        vm.released = { [weak panels] in panels?.release($0) }
        vm.handInTyping = { [weak panels] in panels?.handIn() ?? true }
        vm.handInOnSwitch = { [weak panels] in panels?.handInOnSwitch() ?? true }
        let made = ViewerModel(makeRenderer: { PdfKitRenderer() }, openAddress: { NSWorkspace.shared.open($0) },
                               settings: folders.settings)
        made.markRequested = { [weak vm] in vm?.markSelection($0) }
        viewer = made
        vm.fileWriter = CoordinatedFileWriter()
        vm.fileReader = CoordinatedFileReader.read
        let services = MacToolServices()
        vm.filePicker = services
        vm.fileExporter = services
        vm.clipboard = services
        vm.bringForward = { [unowned self] _ in self.showWindow() }
        // Fires after an open finishes, which can be after the window and this shell are gone.
        vm.becameIdle = { [weak self] in self?.becameIdle() }
        vm.exitRequested = { [unowned self] in self.hub.exitFinished(self) }
        commands = ShellCommands(open: { [unowned self] in self.openWithPanel() },
                                 create: { [unowned self] in self.present { CreateSheet(host: self.vm, close: $0) } },
                                 batch: { [unowned self] in self.present { BatchSheet(host: self.vm, folders: self.folders, close: $0) } },
                                 saveAs: { [unowned self] in self.saveAs($0) },
                                 saveCompact: { [unowned self] in self.saveCompact($0) },
                                 print: { [unowned self] in self.systemPrint($0) },
                                 share: { [unowned self] in self.share($0) },
                                 openElsewhere: { [unowned self] in self.openElsewhere($0) },
                                 importCertificate: { [unowned self] in self.importCertificate() },
                                 openFiles: { [unowned self] in self.open($0) },
                                 moveToNewWindow: { [unowned self] in self.hub.moveToNewWindow($0, from: self) },
                                 windowTargets: { [unowned self] in self.hub.targets(besides: self) },
                                 tabDragging: TabDragging(drop: { [unowned self] in self.hub.drop($0, on: self, at: $1) },
                                                          ended: { [unowned self] in self.hub.dragEnded($0, from: self, $1) }))
        #if LAZYPDF_UITESTS
        if primary { openTestFile() }
        #endif
    }

    func attach(_ window: NSWindow) {
        self.window = window
        hadWindow = true
        hub.windowList.bump()
        if let old = sheetEnd { NotificationCenter.default.removeObserver(old) }
        // A SwiftUI sheet ends its state before the window lets go of it, so the check waits for the window to say so.
        sheetEnd = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.becameIdle() }
        }
        if let point = placeAt {
            placeAt = nil
            window.setFrameTopLeftPoint(NSPoint(x: point.x - 80, y: point.y + 20))
        }
        update(WindowState(vm.activeDocument))
        restoreSession()
        closeGuard = CloseGuard.ensure(on: window, existing: closeGuard, hasTabs: { [weak self] in self?.vm.documents.isEmpty == false },
                                       quit: { NSApp.terminate(nil) }, others: { [weak self] in self?.otherWindowShows() ?? false },
                                       closeHere: { [weak self] in self?.closeFromButton() ?? true })
    }

    /// False while a sheet of this window is up, which a moved tab must not arrive under.
    var isFree: Bool { window?.attachedSheet == nil }

    private func otherWindowShows() -> Bool {
        hub.hasOtherVisibleWindow(self) || (!isPrimary && vm.documents.isEmpty)
    }

    /// Lets go of what the window held once it is gone, so the shell is freed with it.
    func teardown() {
        viewer.show(nil)
        closeGuard = nil
        if let sheetEnd { NotificationCenter.default.removeObserver(sheetEnd) }
        sheetEnd = nil
    }

    // Another window is showing, so the red button closes this one once its own tabs have been answered for.
    private func closeFromButton() -> Bool {
        if vm.requestExit() { return finishClose() }
        closing = vm.closeQuestion != nil
        return false
    }

    // The primary is never closed: it is hidden, empty, and comes back for Finder's files and the Dock. Returns whether
    // the window should still be closed by the system.
    private func finishClose() -> Bool {
        if !isPrimary { return true }
        window?.orderOut(nil)
        return false
    }

    /// The close of this window has been answered for.
    func closeWindow() {
        if isPrimary { window?.orderOut(nil) } else { window?.close() }
    }

    func update(_ state: WindowState) {
        window?.title = state.title
        hub.windowList.bump()
        window?.representedURL = state.url
        window?.isDocumentEdited = state.dirty
    }

    // Files Finder hands over at launch arrive about when the window does, so they get a turn first and win. Only the primary
    // restores: a second window starts empty.
    private func restoreSession() {
        if restored || !isPrimary { return }
        restored = true
        Task {
            await Task.yield()
            if filesFromOutside { return }
            await vm.reopenLastSession()
        }
    }

    func showWindow() {
        // A window that was closed for good has nothing to show; the scene is asked for a new one.
        guard let window else {
            if hadWindow { hub.reopenWindow(of: self) }
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // The sheets of the Create and Batch tiles hang from the window, as a dialog does on Windows.
    private func present<Content: View>(_ content: (@escaping () -> Void) -> Content) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let close = { [weak self, weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet)
            sheet.orderOut(nil)
            self?.becameIdle()
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
            becameIdle()
        }
    }

    /// A question was answered, a sheet closed or a file finished opening.
    func becameIdle() {
        if closeWhenIdle { hub.closeEmpty(self) }
    }

    private func openWithPanel() {
        open(MacFilePanels.open())
    }

    /// Finder, the Dock and other programs: files, and lazypdf: addresses.
    func handle(_ urls: [URL]) {
        filesFromOutside = true
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
        guard let layout = askPrintLayout(tab) else { return }
        if layout.isPlain {
            run(tab.canDraw ? MacSystemPrint.operation(tab.session, password: tab.password, title: tab.title) : nil, tab, dropped: 0, panelShown: false)
        } else if layout.isEmpty(count: tab.document.pages.count) {
            vm.showProblem(Problem(L10n.t("Not printed"), L10n.t("None of the pages you chose are left to print.")))
        } else if tab.canDraw {
            // The sheets are made for the paper picked in the panel, so the panel comes first and the operation runs without one.
            let info = MacSystemPrint.sheetInfo(NSPrintInfo.shared, layout: layout)
            guard NSPrintPanel().runModal(with: info) == NSApplication.ModalResponse.OK.rawValue else { return }
            let source = tab.document
            let paper = info.paperSize
            Task {
                var sheets: PrintSheets?
                var failure: Error?
                try? await vm.runBusy(L10n.t("Making the pages to print")) { token in
                    do {
                        sheets = try await layout.fileInBackground(source, sheetWidth: paper.width, sheetHeight: paper.height, token: token)
                    } catch {
                        failure = error
                        throw error
                    }
                }
                // A cancel is not a failure to report.
                if failure is CancellationError { return }
                let made = sheets.flatMap { MacSystemPrint.operation($0, layout: layout, title: tab.title, info: info) }
                run(made, tab, dropped: sheets?.dropped ?? 0, panelShown: true)
            }
        } else {
            run(nil, tab, dropped: 0, panelShown: false)
        }
    }

    private func run(_ made: NSPrintOperation?, _ tab: DocumentTab, dropped: Int, panelShown: Bool) {
        guard let operation = made else {
            vm.showProblem(Problem(L10n.t("Not printed"),
                                   L10n.t("{0} could not be prepared for printing. Save it and print it from another program.", tab.title)))
            return
        }
        if let note = PrintLayout.droppedNote(dropped) { vm.showNotice(L10n.t("Left off the sheets"), note) }
        if panelShown { operation.showsPrintPanel = false }
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    // The panel has pages per sheet, a page range, odd or even pages and a page order of its own, so only the booklet
    // and its binding are asked for.
    private func askPrintLayout(_ tab: DocumentTab) -> PrintLayout? {
        let remembered = PrintLayout(booklet: PrintLayout.remembered(AppPreferencesStore.load(vm.settings)).booklet)
        let choice = PrintLayoutChoice(remembered: remembered, rightToLeft: ViewerSettings.read(tab.document).rightToLeft,
                                       documentPages: tab.document.pages.count)
        // The alert keeps the size it is given, so it is made for the tallest state, with the booklet rows showing.
        var tallest = remembered
        tallest.booklet = true
        let measure = PrintLayoutChoice(remembered: tallest, rightToLeft: choice.layout.rightToLeft, documentPages: tab.document.pages.count)
        let height = NSHostingView(rootView: PrintLayoutView(choice: measure, onPhone: false).frame(width: 300)).fittingSize.height
        let view = NSHostingView(rootView: PrintLayoutView(choice: choice, onPhone: false).frame(width: 300, height: height, alignment: .top))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: height)
        let alert = NSAlert()
        alert.messageText = L10n.t("Print layout")
        alert.accessoryView = view
        alert.addButton(withTitle: L10n.t("Print"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let layout = choice.layout
        AppPreferencesStore.update(vm.settings) { layout.remember(in: &$0) }
        return layout
    }

    // Preview, the usual default app, cannot show XFA. An Adobe reader does, so it gets the file when it is installed;
    // otherwise the person picks the app, as Finder's Open With > Other does.
    private func openElsewhere(_ tab: DocumentTab) {
        guard let file = tab.url ?? stage(tab) else { return }
        if let app = Self.xfaViewer() {
            open(file, with: app)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.t("Open")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        if let own = Bundle.main.bundleIdentifier, Bundle(url: app)?.bundleIdentifier == own { return }
        open(file, with: app)
    }

    private static func xfaViewer() -> URL? {
        let readers = ["com.adobe.Reader", "com.adobe.Acrobat.Pro", "com.adobe.Acrobat"]
        // A copy left in the Trash is still known to LaunchServices.
        return readers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first { !$0.path.contains("/.Trash/") }
    }

    private func open(_ file: URL, with app: URL) {
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.vm.showProblem(Problems.open(error, file.lastPathComponent)) }
        }
    }

    // A copy of the document as it is now, for what has no file to hand over.
    private func stage(_ tab: DocumentTab) -> URL? {
        let folder = folders.printCopies.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = tab.title.lowercased().hasSuffix(".pdf") ? tab.title : tab.title + ".pdf"
        let file = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(tab.session.current).write(to: file)
        } catch {
            vm.showProblem(Problems.save(error, tab.title))
            return nil
        }
        return file
    }

    private func share(_ tab: DocumentTab) {
        guard let view = window?.contentView, let file = stage(tab) else { return }
        NSSharingServicePicker(items: [file]).show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }

    /// The close question went away: its answer was Cancel, or the tab was closed and the window finished.
    func closeQuestionChanged() {
        hub.closeQuestionChanged(self)
    }

    #if LAZYPDF_UITESTS
    // The UI tests cannot hand the sandboxed app a path it may read, so the file comes in the arguments and is written to
    // the app's own temporary folder first: -LazyPDFTestFile name.pdf -LazyPDFTestData <base64>, and the same with a 2 after
    // the key names for a second file. Only the UI-test build
    // compiles it (-DLAZYPDF_UITESTS), so the store binary ignores these arguments.
    private static func argument(_ key: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: key).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    private func openTestFile() {
        let arguments = ProcessInfo.processInfo.arguments
        // One call, or the files open as separate jobs in no fixed order.
        var urls: [URL] = []
        for suffix in ["", "2"] {
            guard let name = Self.argument("-LazyPDFTestFile" + suffix, in: arguments),
                  let text = Self.argument("-LazyPDFTestData" + suffix, in: arguments), let data = Data(base64Encoded: text) else { break }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            if (try? data.write(to: url)) != nil { urls.append(url) }
        }
        if !urls.isEmpty { open(urls) }
    }
    #endif
}
#endif
