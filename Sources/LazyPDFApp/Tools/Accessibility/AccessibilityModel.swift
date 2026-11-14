import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Accessibility/AccessibilityPanel.xaml.cs: the accessibility tool, the check with its fixes,
// the tag tree (AccessibilityModel+Tags.swift), the figures' descriptions (+Figures) and the reading order read aloud (+Read).
// This file has the check and the way the four views take turns.

public enum AccessibilityView {
    case check, tags, figures, read
}

@MainActor
@Observable
public final class AccessibilityModel: ToolPanelModel {
    public private(set) var view = AccessibilityView.check
    public private(set) var isSigned = false

    /// The file has no tags and the tagger would take it.
    public private(set) var untagged = false

    /// Set while the tagger edits the document, so the panel holds still.
    public internal(set) var isTagging = false

    public private(set) var rows: [CheckRow] = []
    public private(set) var checkSummary = ""

    public internal(set) var tagNodes: [TagNode] = []
    public internal(set) var tagsNote = ""

    public internal(set) var figures: [FigureRow] = []
    public internal(set) var figuresNote = ""
    public internal(set) var selectedFigure: Int?
    public internal(set) var altText = ""
    public internal(set) var canSaveAlt = false
    public internal(set) var canFindBare = false
    public internal(set) var figurePicture: PdfRgbaImage?
    public internal(set) var figureNoPicture = false

    public internal(set) var lines: [String] = []
    public internal(set) var readNote = ""
    public internal(set) var canRead = false
    public internal(set) var isReading = false
    public internal(set) var readIndex: Int?

    var tab: DocumentTab?
    var host: ToolHost?
    var viewer: DocumentViewer?
    var report: AccessibilityReport?

    // Each view is built when it is shown, and again when the file changed since.
    var checkStale = true
    var treeStale = true
    var readStale = true

    @ObservationIgnored var tree: StructureTree?
    @ObservationIgnored var treeCopy: PdfDocument?
    @ObservationIgnored var treeLock = NSLock()
    @ObservationIgnored var allFigures: [FigureRow] = []
    @ObservationIgnored var treeCount = 0
    @ObservationIgnored var treeFailed = false
    @ObservationIgnored var treeTicket = 0
    @ObservationIgnored var pictureTicket = 0
    @ObservationIgnored var readTicket = 0

    /// Text typed for a figure and not saved yet, by FigureRow.key, so moving to another figure does not lose it.
    @ObservationIgnored var drafts: [Int: String] = [:]

    /// The figures the drafts were typed against, to tell whether a tag change touched one.
    @ObservationIgnored var checkedFigures: [FigureRow] = []

    /// What a tab keeps while another tab or tool is shown: its drafts and the figures they were typed against.
    @ObservationIgnored var kept: [ObjectIdentifier: (tab: WeakTab, drafts: [Int: String], checked: [FigureRow])] = [:]

    struct WeakTab {
        weak var tab: DocumentTab?
    }

    /// How a typed description goes into the tags; a test replaces it to make the write fail.
    @ObservationIgnored var setAlt: (PdfDocument, StructureTree, StructElement, String) throws -> Void = AccessibilityEdits.setAlt

    /// The figure to show when the list is built: the one that was shown, or the next one after a save.
    @ObservationIgnored var figureNumber = 0

    @ObservationIgnored var reading: Task<Void, Never>?
    @ObservationIgnored var speaker: Speaker?
    @ObservationIgnored let makeSpeaker: @MainActor () -> Speaker

    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var quiet: CancelToken?
    @ObservationIgnored private var checkTicket = 0

    public init(speaker: (@MainActor () -> Speaker)? = nil) {
        #if canImport(AVFoundation)
        makeSpeaker = speaker ?? { SystemSpeaker() }
        #else
        makeSpeaker = speaker ?? { NoSpeaker() }
        #endif
    }

    // Adding tags runs as the pinned action so the window holds still while the document is being edited.
    public var action: ToolAction? {
        if view == .tags && untagged {
            return ToolAction(L10n.t("Add tags"), symbol: "tag", canRun: { [self] in tab != nil }, run: { [self] in await addTags() })
        }
        return ToolAction(L10n.t("Check"), symbol: "checkmark.shield", canRun: { [self] in tab != nil }, run: { [self] in await runCheck() })
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.host = host
        self.viewer = viewer
        checkStale = true
        treeStale = true
        readStale = true
        view = host.takeTaggingRequest() ? .tags : .check
        kept = kept.filter { $0.value.tab.tab != nil }
        if let back = kept.removeValue(forKey: ObjectIdentifier(tab)) { (drafts, checkedFigures) = (back.drafts, back.checked) }
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.fileChanged() })
        refresh()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        quiet?.cancel()
        checkTicket += 1
        pictureTicket += 1
        treeTicket += 1
        readTicket += 1
        stopReading()
        readIndex = nil
        report = nil
        dropTree()
        if let tab, !drafts.isEmpty { kept[ObjectIdentifier(tab)] = (WeakTab(tab: tab), drafts, checkedFigures) }
        drafts = [:]
        checkedFigures = []
        figureNumber = 0
        rows = []
        tagNodes = []
        figures = []
        lines = []
        checkSummary = ""
        selectedFigure = nil
        figurePicture = nil
        tab = nil
        host = nil
        viewer = nil
    }

    public func setView(_ next: AccessibilityView) {
        if tab == nil { return }
        view = next
        if next != .read { stopReading() }
        refresh()
    }

    private func fileChanged() {
        checkStale = true
        treeStale = true
        readStale = true
        stopReading()
        refresh()
    }

    // Brings the view in sight up to date.
    func refresh() {
        guard let tab else { return }
        untagged = AccessibilityEdits.canAddTags(tab.document)
        isSigned = tab.document.isSigned
        if view == .check && checkStale {
            Task { await checkQuietly() }
        } else if (view == .tags || view == .figures) && treeStale {
            loadTree()
        } else if view == .read && readStale {
            buildRead()
        }
    }

    private func runCheck() async {
        guard let host, tab != nil else { return }
        view = .check
        stopReading()
        quiet?.cancel()
        var finished = false
        await ChangeGate.guardedAsync(host, L10n.t("Check")) { [self] in
            try await host.runBusy(L10n.t("Checking the file")) { token in finished = try await check(token) }
        }
        if finished { host.setStatus(checkStatus) }
    }

    private func checkQuietly() async {
        quiet?.cancel()
        let token = CancelToken()
        quiet = token
        _ = try? await check(token)
    }

    private struct Checked {
        let report: AccessibilityReport
        let title: String
        let language: String
        let canTag: Bool
    }

    // False when the check did not produce a report.
    func check(_ token: CancelToken) async throws -> Bool {
        guard let tab, let host else { return false }
        checkTicket += 1
        let ticket = checkTicket
        checkStale = false
        checkSummary = L10n.t("Checking the file")
        let open = OpenCopy.of(tab, host)
        let name = tab.title
        do {
            let found = try await ToolDocuments.run(token) { () throws -> Checked in
                let copy = try open()
                return Checked(report: try AccessibilityChecker.check(copy), title: AccessibilityEdits.titleOf(copy, name),
                               language: AccessibilityEdits.languageOf(copy), canTag: AccessibilityEdits.canAddTags(copy))
            }
            if ticket != checkTicket || self.tab !== tab { return false }
            showRows(found.report, found.title, found.language, found.canTag)
            return true
        } catch is CancellationError {
            if ticket == checkTicket {
                report = nil
                rows = []
                checkSummary = L10n.t("Check stopped. Press Check to run it again.")
            }
            throw CancellationError()
        } catch where error is PdfReadException || error is InvalidOperationException {
            if ticket != checkTicket { return false }
            report = nil
            rows = []
            checkSummary = L10n.t("The file could not be checked.")
            return false
        }
    }

    private func showRows(_ report: AccessibilityReport, _ title: String, _ language: String, _ canTag: Bool) {
        let typed = Dictionary(rows.filter(\.edited).map { ($0.editor, $0.value) }, uniquingKeysWith: { _, last in last })
        let made = report.items.map { item in
            CheckRow(item, value: item.rule == .title ? title : item.rule == .language ? language : "", canAddTags: canTag)
        }
        for row in made { if let value = typed[row.editor], row.hasEditor { row.value = value } }
        rows = made
        self.report = report
        checkSummary = L10n.t("{0} passed, {1} failed, {2} need a person.", report.passed, report.failed, report.needsPerson)
    }

    private var checkStatus: String { L10n.t("{0} failed, {1} passed", report?.failed ?? 0, report?.passed ?? 0) }

    /// Saves the title or language of a row.
    public func save(_ row: CheckRow) {
        guard let tab, let host else { return }
        if row.editor == .title && row.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            host.showProblem(Problem(L10n.t("Title is empty"), L10n.t("Type a title for the file, then save it.")))
            return
        }
        apply(tab, host, row, row.editorName)
    }

    /// The button of a failed row.
    public func act(_ row: CheckRow) {
        guard let tab, let host else { return }
        switch row.action {
        case .addTags: setView(.tags)
        case .describeFigures: setView(.figures)
        default: apply(tab, host, row, row.actionText)
        }
    }

    /// The place button of a row: the page of the next place.
    public func place(_ row: CheckRow) {
        viewer?.goToPage(row.nextPage())
    }

    private func apply(_ tab: DocumentTab, _ host: ToolHost, _ row: CheckRow, _ label: String) {
        ChangeGate.run(tab, host, label) { [self] in
            guard self.tab === tab else { return }
            do {
                if try AccessibilityEdits.apply(tab.document, row), try tab.commit(label) {
                    host.setStatus(L10n.t("Saved."))
                } else {
                    host.setStatus(L10n.t("Nothing to change."))
                }
            } catch is ArgumentException {
                host.showProblem(Problem(L10n.t("Language is not valid"), L10n.t("Write the language as a tag such as en-US or tr-TR.")))
            } catch is PdfReadException {
                try? tab.session.discard()
                host.showProblem(Problem(L10n.t("Not saved"), L10n.t("The change could not be written. Save a copy of the file and try again.")))
            }
        }
    }
}
