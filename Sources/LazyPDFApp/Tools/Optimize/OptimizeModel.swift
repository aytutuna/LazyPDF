import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Optimize/OptimizePanel.xaml.cs: Make smaller, where the bytes of the file are, a preset or
// custom settings, and the run.

@MainActor
@Observable
public final class OptimizeModel: ToolPanelModel {
    public static let dpiSteps = [0, 72, 96, 150, 200, 300]

    public private(set) var rows: [AuditRow] = []

    /// The line above the list: the file size, or why there is no list.
    public private(set) var total = ""

    public var preset = SizePreset.balanced
    public var dpiIndex = 3
    public var quality = 75
    public var trimFonts = true
    public var blackWhite = true
    public var dropAppData = true
    public var dropPrivateKeys = false
    public var grayscale = false
    public var fastWebView = false

    public let output = OutputChoice()

    var tab: DocumentTab?
    var host: ToolHost?
    @ObservationIgnored private let codec: ImageCodec?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var ticket = 0

    public init(codec: ImageCodec? = nil) {
        self.codec = codec
    }

    public var action: ToolAction? {
        ToolAction(L10n.t("Make smaller"), symbol: "arrow.down.right.and.arrow.up.left",
                   canRun: { [self] in tab.map { !ToolDocuments.needsOwner($0.document) } ?? false }, run: { [self] in await run() })
    }

    public var dpiLabels: [String] {
        Self.dpiSteps.map { $0 == 0 ? L10n.t("Keep as is") : L10n.t("{0} dpi", $0) }
    }

    public var presetNote: String {
        switch preset {
        case .small: return L10n.t("Smallest file. Pictures drop to 96 dpi, black and white pictures become 1-bit, and some detail is lost.")
        case .balanced: return L10n.t("Good for email and screens. Pictures drop to 150 dpi and are saved as JPEG at 80%. Some detail is lost.")
        case .high: return L10n.t("Keeps detail for printing. Pictures stay up to 300 dpi. Very little is lost.")
        case .custom: return ""
        }
    }

    public var choice: OptimizeChoice {
        OptimizeChoice(preset, CustomSize(imageDpi: Self.dpiSteps[min(max(dpiIndex, 0), Self.dpiSteps.count - 1)], jpegQuality: quality,
                                          trimFonts: trimFonts, blackWhite: blackWhite, dropAppData: dropAppData,
                                          dropPrivateKeys: dropPrivateKeys),
                       grayscale: grayscale, fastWebView: fastWebView)
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.host = host
        output.configure(tab, removesSignatures: false)
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.output.configure(tab, removesSignatures: false)
            self.showAudit()
        })
        showAudit()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        ticket += 1
        tab = nil
        host = nil
    }

    /// Looks through the file as it is; the task ends when the list is shown.
    @discardableResult
    public func showAudit() -> Task<Void, Never> {
        ticket += 1
        let mine = ticket
        guard let tab, let host else { return Task {} }
        rows = []
        if ToolDocuments.needsOwner(tab.document) {
            total = L10n.t("This file is protected. Open it with its owner password to use this tool.")
            return Task {}
        }
        total = L10n.t("Looking through the file.")
        let file = tab.session.current
        let password = tab.password
        let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
        let revision = tab.revision
        return Task { [self] in
            let audit: SpaceAudit
            do {
                audit = try await Task.detached { try OptimizeJob.audit(file, password: password, certificate: certificate) }.value
            } catch {
                if ticket == mine, self.tab === tab, tab.revision == revision { total = L10n.t("The file could not be searched.") }
                return
            }
            guard ticket == mine, self.tab === tab, tab.revision == revision else { return }
            rows = AuditRow.of(audit)
            total = L10n.t("File size {0}", SizeText.of(audit.fileSize))
        }
    }

    private func run() async {
        guard let tab, let host else { return }
        let name = L10n.t("Make smaller")
        await ChangeGate.guardedAsync(host, name) { [self] in
            let choice = choice
            let replace = output.replace
            if OutputWriter.refuses(host, tab, replace: replace) { return }
            let revision = tab.revision
            let file = tab.session.current
            let password = tab.password
            let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
            let title = L10n.t("{0} (smaller)", (tab.title as NSString).deletingPathExtension) + ".pdf"
            let codec = codec

            var outcome: OptimizeOutcome?
            try await host.runBusy(L10n.t("Making the file smaller")) { token in
                outcome = try await ToolDocuments.run(token) {
                    try OptimizeJob.run(file, password: password, certificate: certificate, choice: choice, codec: codec, token: token)
                }
            }
            guard let outcome else { return }

            let saved = outcome.sizeBefore - outcome.sizeAfter
            if saved <= 0 && !choice.grayscale && !choice.fastWebView {
                host.showNotice(L10n.t("Already small"), choice.preset == .small
                    ? L10n.t("This file is as small as it gets.")
                    : L10n.t("These settings cannot make this file smaller. Try the Small preset."), nil)
                return
            }
            if !(await OutputWriter.deliver(host, tab, revision: revision, outcome.bytes, replace: replace, newTitle: title)) { return }

            let sizes = saved > 0
                ? L10n.t("{0} to {1}, {2}% smaller.", SizeText.of(outcome.sizeBefore), SizeText.of(outcome.sizeAfter),
                         SizeText.percent(outcome.sizeBefore, outcome.sizeAfter))
                : L10n.t("{0} to {1}.", SizeText.of(outcome.sizeBefore), SizeText.of(outcome.sizeAfter))
            host.showNotice(saved > 0 ? L10n.t("File made smaller") : L10n.t("File rewritten"), ([sizes] + outcome.notes + (outcome.dropped > 0 ? [PageJobs.droppedText(outcome.dropped)] : [])).joined(separator: " "), nil)
            host.setStatus(saved > 0 ? L10n.t("{0} smaller.", SizeText.of(saved)) : L10n.t("Done."))
        }
    }
}
