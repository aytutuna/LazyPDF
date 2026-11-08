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
    }

    let id = UUID()
    let kind: Kind
}

@MainActor
@Observable
final class IOSShell {
    let vm: AppViewModel
    let folders: IOSAppFolders
    var sheet: SheetRequest?

    private let certificates: IOSCertificates
    @ObservationIgnored private var viewers: [UUID: ViewerModel] = [:]
    @ObservationIgnored private var picking: CheckedContinuation<[PickedFile], Never>?

    init() {
        let keys = IOSCertificates()
        let folders = IOSAppFolders()
        certificates = keys
        self.folders = folders
        vm = AppViewModel(renderers: { PdfKitRenderer() }, codec: ImageIOCodec(), fonts: CoreTextFontSource(),
                          sisters: IOSSisterApps(), certificates: keys, bookmarks: IOSBookmarks(), folders: folders)
        vm.fileWriter = CoordinatedFileWriter()
        try? FileManager.default.removeItem(at: Self.shared)
    }

    var commands: ShellCommands {
        ShellCommands(open: { [self] in
            Task { await openPicked() }
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
        viewers[tab.id] = made
        return made
    }

    func dropClosedViewers() {
        let open = Set(vm.documents.map(\.id))
        viewers = viewers.filter { open.contains($0.key) }
    }

    // Files from Files, Mail or another app's Open In come with a grant the app can hold. The address names files by path,
    // which the app cannot read and must not open on a caller's say-so, so the file has to come through the system.
    func receive(_ url: URL) {
        if url.isFileURL {
            Task { await vm.open(url, access: SecurityScopedAccess.start(url)) }
        } else if !LazyPdfAddress.parse(url.absoluteString).isEmpty {
            vm.showNotice(L10n.t("File not opened"), L10n.t("An address cannot open a file here. Share the file to Lazy PDF or open it from Files."))
        }
    }

    // A hidden launch argument for the UI tests, `-uitestOpen <path>`, honoured in the simulator only.
    func openLaunchFixture() async {
        #if targetEnvironment(simulator)
        guard let path = UserDefaults.standard.string(forKey: "uitestOpen") else { return }
        await vm.open(URL(fileURLWithPath: path))
        #endif
    }

    func finishPicking(_ files: [PickedFile]) {
        picking?.resume(returning: files)
        picking = nil
        sheet = nil
    }

    func sheetClosed() {
        if sheet == nil { finishPicking([]) }
    }

    private func pick(_ kind: SheetRequest.Kind) async -> [PickedFile] {
        finishPicking([])
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

    // The picker copies a finished file to the place the person names; the tab then saves there itself, through the
    // coordinated writer, so its state and its grant follow the new file.
    private func saveAs(_ tab: DocumentTab, compact: Bool) async -> Bool {
        let name = (tab.title as NSString).deletingPathExtension + ".pdf"
        guard let staged = stage(tab, name: name, rewritten: compact) else { return false }
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        guard let file = await pick(.export(staged)).first else { return false }
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
        guard let file = stage(tab, name: name, rewritten: false, in: Self.shared) else { return }
        sheet = SheetRequest(kind: .share(file))
    }

    private static var shared: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
    }

    private func stage(_ tab: DocumentTab, name: String, rewritten: Bool, in root: URL? = nil) -> URL? {
        let folder = (root ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(name)
        do {
            let data = rewritten ? try IOSSystemPrint.item(tab.session) : Data(tab.session.current)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
            return file
        } catch {
            vm.showProblem(Problems.save(error, tab.title))
            return nil
        }
    }
}
#endif
