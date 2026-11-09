import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Standards/StandardsPanel.xaml.cs: checks the file against a PDF/A level and converts it to
// one. The words say that the file passes Lazy PDF's checks and never that it conforms: the validator has not been compared
// with an outside one.

public enum StandardsMode {
    case check, convert
}

@MainActor
@Observable
public final class StandardsModel: ToolPanelModel {
    /// The most rows listed; the rest are counted.
    public nonisolated static let rowsShown = 100

    public nonisolated static let levels: [PdfALevel] = [.a1b, .a2b, .a2u, .a3b, .a3u, .a4]

    public private(set) var mode = StandardsMode.check
    public private(set) var levelIndex = 1
    public private(set) var verdict = ""
    public private(set) var rows: [IssueRow] = []
    public private(set) var rest = ""
    public private(set) var showsResult = false

    /// A run is going, or was let go by Cancel and has not ended yet: the button waits so that runs do not pile up.
    public private(set) var working = false

    // Bumped when the file changes, so what is derived from it is read again.
    private var fileVersion = 0
    var tab: DocumentTab?
    var viewer: DocumentViewer?
    var host: ToolHost?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var ticket = 0
    @ObservationIgnored private let fonts: FontSource?

    public init(fonts: FontSource? = nil) {
        self.fonts = fonts
    }

    public var level: PdfALevel { Self.levels[levelIndex] }

    public var action: ToolAction? {
        switch mode {
        case .check:
            return ToolAction(L10n.t("Check"), symbol: "checkmark.seal", canRun: { [self] in tab != nil && !working }, run: { [self] in await check() })
        case .convert:
            return ToolAction(L10n.t("Convert to {0}", level.name()), symbol: "arrow.triangle.2.circlepath",
                              canRun: { [self] in tab != nil && !working }, run: { [self] in await convert() })
        }
    }

    public var caveat: String { L10n.t("These are Lazy PDF's own checks. No outside validator has confirmed them.") }

    public var modeNote: String {
        mode == .convert
            ? L10n.t("Makes a new file and tries to meet the level. This file stays as it is.")
            : L10n.t("Lists the rules the file breaks. Nothing is changed.")
    }

    public var levelNote: String { StandardsText.describe(level) }

    /// What converting costs this file, said before it is done.
    public var losses: String {
        _ = fileVersion
        guard mode == .convert, let document = tab?.document else { return "" }
        return StandardsText.losses(signed: document.isSigned, encrypted: document.isEncrypted)
    }

    public func setMode(_ mode: StandardsMode) {
        self.mode = mode
    }

    public func setLevel(_ index: Int) {
        guard Self.levels.indices.contains(index), index != levelIndex else { return }
        levelIndex = index
        if tab != nil { clear() }
    }

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
        rows = []
        tab = nil
        viewer = nil
        host = nil
    }

    // What a verdict says is about the bytes it was made from.
    private func clear() {
        ticket += 1
        fileVersion += 1
        showsResult = false
        rows = []
    }

    /// Goes to the next page the rule is broken on.
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

    private func check() async {
        guard let tab, let host else { return }
        let level = self.level
        ticket += 1
        let mine = ticket
        let open = OpenCopy.of(tab, host)
        let done = ended()
        var report: PdfAReport?
        var letGo = false
        working = true
        do {
            try await host.runBusy(L10n.t("Checking {0}", level.name())) { token in
                do {
                    report = try await ToolDocuments.run(token) {
                        defer { done() }
                        try token.throwIfCancelled()
                        return PdfAValidator.validate(try open(), level)
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
        guard let report, mine == ticket, self.tab === tab else { return }
        show(report)
        host.setStatus(report.isValid ? L10n.t("Passes Lazy PDF's {0} checks.", level.name()) : L10n.t("Fails {0} checks.", level.name()))
    }

    private func show(_ report: PdfAReport) {
        let grouped = IssueRow.group(report.issues)
        let name = report.level.name()
        verdict = report.isValid
            ? L10n.t("Passes Lazy PDF's checks for {0}.", name)
            : L10n.t("Does not pass the checks for {0}. Rules broken: {1}.", name, grouped.count)
        rows = Array(grouped.prefix(Self.rowsShown))
        rest = grouped.count > Self.rowsShown ? L10n.t("{0} more rules are not listed.", grouped.count - Self.rowsShown)
            : report.truncated ? L10n.t("The list stops at 1000 findings.") : ""
        showsResult = true
    }

    private func convert() async {
        guard let tab, let host else { return }
        let level = self.level
        let job = ConvertJob(tab, host)
        let fonts = self.fonts
        let done = ended()
        var made: PdfAConversion?
        var letGo = false
        working = true
        do {
            try await host.runBusy(L10n.t("Converting to {0}", level.name())) { token in
                do {
                    made = try await ToolDocuments.run(token) {
                        defer { done() }
                        try token.throwIfCancelled()
                        return try job.run(level, fonts)
                    }
                } catch is CancellationError {
                    letGo = true
                    throw CancellationError()
                }
            }
        } catch {
            working = false
            host.showProblem(Problem(L10n.t("Not converted"), L10n.t("The file could not be converted.")))
            return
        }
        if !letGo { working = false }
        guard let made else { return }
        guard let bytes = made.bytes else {
            host.showProblem(Problem(L10n.t("Not converted"), made.refusal ?? L10n.t("The file could not be converted.")))
            return
        }
        await host.openNew(bytes, title: StandardsText.convertedName(tab.title, level, clean: made.isClean), password: nil, certificate: nil)
        host.showNotice(StandardsText.convertedTitle(made), StandardsText.convertedText(made, level), nil)
        if let now = self.tab, now !== tab { await check() }
    }
}
