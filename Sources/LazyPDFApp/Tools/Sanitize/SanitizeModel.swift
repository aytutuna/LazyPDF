import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Sanitize/SanitizePanel.xaml.cs: Clean for sharing, what the file holds that others could
// read, a switch for each kind, and the run.

@MainActor
@Observable
public final class SanitizeModel: ToolPanelModel {
    public private(set) var rows: [SanitizeRow] = []

    /// The line above the list: that the file is being searched, what the search found, or why it cannot be searched.
    public private(set) var found = L10n.t("Looking through the file.")

    public let output = OutputChoice()

    var tab: DocumentTab?
    var host: ToolHost?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var ticket = 0

    public init() {}

    public var action: ToolAction? {
        ToolAction(L10n.t("Clean file"), symbol: "eraser", canRun: { [self] in tab != nil && rows.contains { $0.isChecked } },
                   run: { [self] in await run() })
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.host = host
        output.configure(tab, removesSignatures: true)
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.output.configure(tab, removesSignatures: true)
            self.scan()
        })
        scan()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        ticket += 1
        tab = nil
        host = nil
    }

    public func setChecked(_ row: SanitizeRow, _ on: Bool) {
        guard let at = rows.firstIndex(where: { $0.id == row.id }), rows[at].canTick else { return }
        rows[at].isChecked = on
    }

    /// Looks through the file as it is; the task ends when the list is shown.
    @discardableResult
    public func scan() -> Task<Void, Never> {
        ticket += 1
        let mine = ticket
        guard let tab, let host else { return Task {} }
        rows = []
        if ToolDocuments.needsOwner(tab.document) {
            found = L10n.t("This file is protected. Open it with its owner password to use this tool.")
            return Task {}
        }
        found = L10n.t("Looking through the file.")
        let file = tab.session.current
        let password = tab.password
        let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
        let revision = tab.revision
        return Task { [self] in
            let scanned: [SanitizeFinding]
            do {
                scanned = try await Task.detached { try SanitizeJob.scan(file, password: password, certificate: certificate) }.value
            } catch {
                if ticket == mine, self.tab === tab, tab.revision == revision { found = L10n.t("The file could not be searched.") }
                return
            }
            guard ticket == mine, self.tab === tab, tab.revision == revision else { return }
            rows = scanned.map(SanitizeRow.init)
            found = rows.isEmpty ? L10n.t("Nothing found. This file has no hidden data.") : L10n.t("Tick what to remove.")
        }
    }

    private func run() async {
        guard let tab, let host else { return }
        let name = L10n.t("Clean file")
        await ChangeGate.guardedAsync(host, name) { [self] in
            let ticked = Set(rows.filter(\.isChecked).map(\.item))
            let replace = output.replace
            if OutputWriter.refuses(host, tab, replace: replace) { return }
            let revision = tab.revision
            let file = tab.session.current
            let password = tab.password
            let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
            let title = L10n.t("{0} (clean)", (tab.title as NSString).deletingPathExtension) + ".pdf"

            var result: SanitizeResult?
            try await host.runBusy(L10n.t("Cleaning the file")) { token in
                result = try await Task.detached {
                    try SanitizeJob.run(file, password: password, certificate: certificate, ticked: ticked, token: token)
                }.value
            }
            guard let result else { return }
            if !(await OutputWriter.deliver(host, tab, revision: revision, result.bytes, replace: replace, newTitle: title)) { return }

            var text = result.removed.isEmpty ? L10n.t("Nothing was removed.") : L10n.t("Removed: {0}.", SanitizeJob.list(result.removed))
            if !result.kept.isEmpty { text += " " + L10n.t("Left in: {0}.", SanitizeJob.list(result.kept)) }
            host.showNotice(L10n.t("File cleaned"), text, nil)
            host.setStatus(L10n.t("File cleaned."))
        }
    }
}
