import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Compare/ComparePanel.xaml.cs. Compares the open file with another file or with one of its
// own earlier versions. The list of differences jumps to each in the stage and, when the side by side sheet is open, in both of
// its views. A finished comparison stays with the tab it was run for until that tab is compared again.

public enum CompareSource {
    case file, version
}

@MainActor
@Observable
public final class CompareModel: ToolPanelModel {
    private struct Entry {
        weak var tab: DocumentTab?
        let held: HeldComparison
    }

    public var source = CompareSource.file
    public private(set) var versions: [PdfVersion] = []
    public var versionIndex = 0

    /// The other file; nil until one is chosen.
    public private(set) var other: ToolFile?
    public var fileIsOlder = false
    public var byPixels = false
    public var ignoreCase = false
    public var ignoreSpace = false
    public var ignoreEdges = false
    public private(set) var parts = CompareParts.all

    public private(set) var unlockText: String?
    public private(set) var unlockNeedsCertificate = false
    public var password = ""
    public private(set) var certificates: [CertificateChoice] = []
    public var certificateId: String?

    public private(set) var shown: HeldComparison?
    public private(set) var rows: [ChangeRow] = []
    public private(set) var summaryText = ""
    public private(set) var noteText: String?
    public private(set) var isWritingReport = false
    public private(set) var sheetShown = false

    var tab: DocumentTab?
    var host: ToolHost?
    var viewer: DocumentViewer?
    @ObservationIgnored private var flow: CompareFlow?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var helds: [UUID: Entry] = [:]
    @ObservationIgnored private let renderers: () -> DocumentRenderer
    @ObservationIgnored private let fonts: FontSource

    public init(renderers: @escaping () -> DocumentRenderer, fonts: FontSource) {
        self.renderers = renderers
        self.fonts = fonts
    }

    public var action: ToolAction? {
        ToolAction(L10n.t("Compare"), symbol: "rectangle.split.2x1", canRun: { [self] in canRun }, run: { [self] in await run() })
    }

    var canRun: Bool {
        tab != nil && (source == .version ? versions.indices.contains(versionIndex) : other != nil)
    }

    public var chosenText: String { other?.url.lastPathComponent ?? L10n.t("No file chosen") }

    public var versionNames: [String] { versions.map { L10n.t("Version {0}", $0.number) } }

    public var howText: String {
        byPixels ? L10n.t("Compares how the pages look. Use it for scans and drawings.")
            : L10n.t("Compares words, fonts, pictures, notes and form values.")
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        prune()
        self.tab = tab
        self.host = host
        self.viewer = viewer
        flow = CompareFlow(host, renderers, fonts)
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.showVersions(keep: self.versions.indices.contains(self.versionIndex) ? self.versions[self.versionIndex].number : nil, tab)
        })
        showVersions(keep: nil, tab)
        hideUnlock()
        let held = helds[tab.id]?.held
        other = held?.file
        show(held)
    }

    public func detach() {
        watch?.stop()
        watch = nil
        closeSheet()
        show(nil)
        flow = nil
        tab = nil
        host = nil
        viewer = nil
    }

    public func chooseFile() async {
        guard let host, let file = await host.filePicker.pickFiles([.pdf], multiple: false).first else { return }
        choose(file)
    }

    public func choose(_ file: ToolFile) {
        other = file
        hideUnlock()
    }

    public func setPart(_ part: CompareParts, _ on: Bool) {
        if on { parts.insert(part) } else { parts.remove(part) }
        refresh()
    }

    private func run() async {
        guard let tab, let host, let flow else { return }
        await ChangeGate.guardedAsync(host, L10n.t("Compare")) { [self] in
            let version = source == .version
            let options = CompareOptions(ignoreCase: ignoreCase, ignoreWhiteSpace: ignoreSpace, ignoreHeaderFooter: ignoreEdges)
            let typed = password.isEmpty ? nil : password
            let choice = certificates.first { $0.id == certificateId }
            let file = version ? nil : other
            let request = CompareRequest(url: file?.url, version: version ? versions[versionIndex] : nil, fileIsOlder: !version && fileIsOlder,
                                         options: options, byPixels: byPixels, password: typed, certificate: choice)
            let revision = tab.revision
            let made = try await flow.run(tab, request)
            let here = self.tab === tab
            guard let made else {
                if here, let locked = flow.locked { askToUnlock(locked, tried: typed != nil || choice != nil) }
                return
            }
            if let old = helds[tab.id] {
                if here { closeSheet() }
                old.held.dispose()
            }
            let held = HeldComparison(made, file: file, openIsNew: !request.fileIsOlder, revision: revision)
            helds[tab.id] = Entry(tab: tab, held: held)
            if !here { return }
            hideUnlock()
            show(held)
        }
    }

    // A held comparison of a tab that has closed has nothing to show for.
    private func prune() {
        for (id, entry) in helds where entry.tab == nil || entry.tab?.isDisposed == true {
            entry.held.dispose()
            helds[id] = nil
        }
    }

    private func show(_ held: HeldComparison?) {
        shown = held
        if held == nil {
            rows = []
            summaryText = ""
            noteText = nil
        } else {
            refresh()
        }
    }

    private func showVersions(keep: Int?, _ tab: DocumentTab) {
        versions = CompareFlow.earlier(tab.session)
        versionIndex = versions.firstIndex { $0.number == keep } ?? max(versions.count - 1, 0)
    }

    private func askToUnlock(_ problem: PdfReadProblem, tried: Bool) {
        let certificate = problem == .certificateRequired
        let name = other?.url.lastPathComponent ?? ""
        var text = tried ? L10n.t("{0} did not open. Check it and compare again.", name)
            : certificate ? L10n.t("{0} is locked for certificate holders. Pick one that opens it.", name)
            : L10n.t("{0} is locked. Type its password.", name)
        unlockNeedsCertificate = certificate
        if certificate && certificates.isEmpty {
            certificates = host?.certificateChoices() ?? []
            if certificates.isEmpty { text = L10n.t("No certificate with a private key was found on this computer.") }
        }
        unlockText = text
        host?.setStatus(L10n.t("File is locked."))
    }

    private func hideUnlock() {
        unlockText = nil
        password = ""
        certificateId = nil
    }

    private func refresh() {
        guard let held = shown else { return }
        rows = held.session.rows(parts)
        summaryText = CompareFlow.headline(held.session, rows.count)
        noteText = CompareFlow.note(held.session)
        held.window?.setRows(rows)
    }

    /// A row of the list was picked: the sheet goes there when it is open, else the stage does.
    public func go(_ row: ChangeRow) {
        guard let held = shown else { return }
        if let window = held.window {
            window.go(row)
            return
        }
        if row.oldPage < 0 && row.newPage < 0 { return }
        if tab?.revision != held.revision {
            host?.setStatus(L10n.t("File changed. Compare again."))
            return
        }
        let page = held.openIsNew ? row.newPage : row.oldPage
        let area = held.openIsNew ? row.newArea : row.oldArea
        guard page >= 0, let viewer else {
            host?.setStatus(L10n.t("Only in the other file."))
            return
        }
        if let area { viewer.reveal(page, area) } else { viewer.goToPage(page) }
    }

    /// Opens the side by side sheet, which the view presents from `sheetShown`.
    public func openSheet() {
        guard let held = shown, held.window == nil else { return }
        held.window = CompareWindowModel(held.session, rows, renderers)
        sheetShown = true
    }

    public func closeSheet() {
        shown?.window?.close()
        shown?.window = nil
        sheetShown = false
    }

    public func writeReport() async {
        guard let held = shown, let flow, !isWritingReport else { return }
        isWritingReport = true
        defer { isWritingReport = false }
        await flow.writeReport(held.session, parts)
    }
}

#if canImport(PDFKit) && canImport(CoreText)
extension CompareModel {
    public convenience init() {
        self.init(renderers: { PdfKitRenderer() }, fonts: CoreTextFontSource())
    }
}
#endif
