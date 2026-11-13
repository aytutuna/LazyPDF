import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/PdfUa/PdfUaPanel.xaml.cs: checks the file against PDF/UA-1 and, when the check finds nothing
// but what marking writes itself, marks it. The words say that the file passes Lazy PDF's checks and never that it conforms.

@MainActor
@Observable
public final class PdfUaModel: ToolPanelModel {
    /// The most rows listed; the rest are counted.
    public nonisolated static let rowsShown = 100

    public private(set) var verdict = ""
    public private(set) var rows: [IssueRow] = []
    public private(set) var rest = ""
    public private(set) var showsResult = false

    /// The check found nothing but what marking writes itself.
    public private(set) var canMark = false

    /// A run is going, or was let go by Cancel and has not ended yet: the button waits so that runs do not pile up.
    public private(set) var working = false

    var tab: DocumentTab?
    var viewer: DocumentViewer?
    var host: ToolHost?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var ticket = 0
    @ObservationIgnored private var checkAfterChange = false

    public init() {}

    public var action: ToolAction? {
        ToolAction(L10n.t("Check"), symbol: "checkmark.seal", canRun: { [self] in tab != nil && !working }, run: { [self] in await check() })
    }

    public var intro: String { L10n.t("Lists the PDF/UA-1 conditions the file breaks. Nothing is changed until you mark it.") }

    public var personNote: String {
        L10n.t("Reading order, what alt text says and contrast need a person. The Accessibility tool lists them.")
    }

    public var caveat: String { L10n.t("These are Lazy PDF's own checks. No outside validator has confirmed them.") }

    public var markNote: String { L10n.t("Nothing else is wrong. Marking writes the PDF/UA-1 identifier into the file.") }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.clear() })
        clear()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        ticket += 1
        showsResult = false
        canMark = false
        rows = []
        tab = nil
        viewer = nil
        host = nil
    }

    // What a verdict says is about the bytes it was made from.
    private func clear() {
        ticket += 1
        showsResult = false
        canMark = false
        rows = []
        // The tab tells of a change a moment after it is made, so the check of a marked file waits for that.
        if checkAfterChange {
            checkAfterChange = false
            Task { @MainActor [weak self] in await self?.check() }
        }
    }

    /// Goes to the next page the condition is broken on.
    public func visit(_ row: IssueRow) {
        guard row.hasPlaces else { return }
        viewer?.goToPage(row.nextPage())
    }

    // Ends the run's hold on the button once the job itself has ended, which after Cancel is later than the busy bar.
    private func ended() -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor in self?.working = false }
        }
    }

    func check() async {
        guard let tab, let host else { return }
        ticket += 1
        let mine = ticket
        let open = OpenCopy.of(tab, host)
        let done = ended()
        var outcome: UaOutcome?
        var letGo = false
        working = true
        do {
            try await host.runBusy(L10n.t("Checking PDF/UA-1")) { token in
                do {
                    outcome = try await ToolDocuments.run(token) {
                        defer { done() }
                        try token.throwIfCancelled()
                        return try UaOutcome.of(try open())
                    }
                } catch is CancellationError {
                    letGo = true
                    throw CancellationError()
                }
            }
        } catch {
            working = false
            host.showProblem(Problem(L10n.t("Not checked"), L10n.t("The file could not be checked.")))
            return
        }
        if !letGo { working = false }
        guard let outcome, mine == ticket, self.tab === tab else { return }
        show(outcome)
        host.setStatus(outcome.status)
    }

    private func show(_ outcome: UaOutcome) {
        let grouped = IssueRow.group(outcome.report.issues)
        verdict = outcome.verdict(grouped.count)
        canMark = outcome.canMark
        rows = Array(grouped.prefix(Self.rowsShown))
        rest = grouped.count > Self.rowsShown ? L10n.t("{0} more conditions are not listed.", grouped.count - Self.rowsShown)
            : outcome.report.truncated ? L10n.t("The list stops at 1000 findings.") : ""
        showsResult = true
    }

    public func mark() async {
        guard let tab, let host, !working else { return }
        let name = L10n.t("Mark as PDF/UA")
        await ChangeGate.runAsync(tab, host, name) { [self] in
            guard self.tab === tab else { return }
            let document = tab.document
            var result: PdfUaMarkResult?
            try await host.runBusy(name) { token in
                result = try await ToolDocuments.run(token) { try PdfUaValidator.mark(document, PanelDates.now()) }
            }
            guard let result else { return }
            guard result.marked else {
                host.showProblem(Problem(L10n.t("Not marked"),
                                         L10n.t("The file does not pass the checks, or its metadata cannot be changed. Check it again.")))
                return
            }
            if try !tab.commit(name) { return }
            host.showNotice(L10n.t("Marked as PDF/UA-1"),
                            L10n.t("The file now names PDF/UA-1. It passes Lazy PDF's checks; a person still has to judge the reading order and the alt text."), nil)
            checkAfterChange = true
        }
    }
}
