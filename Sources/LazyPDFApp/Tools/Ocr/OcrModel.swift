import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Ocr/OcrPanel.xaml.cs: Make searchable, which pages and in what language, then the text
// layer, and its correction (OcrModel+Words.swift) and removal.

/// Stands in where the system has no text recognition.
struct NoTextRecognizer: TextRecognizer {
    func recognizeAsync(_ image: PdfRgbaImage, _ language: String) async throws -> [OcrWord] {
        throw InvalidOperationException(L10n.t("This device cannot read {0} text.", language))
    }
}

@MainActor
@Observable
public final class OcrModel: ToolPanelModel {
    public private(set) var languages: [OcrLanguage] = []

    /// The tag of the language chosen; empty when the system has none.
    public var language = ""
    public private(set) var languageNote = ""

    public private(set) var rows: [PageRow] = []
    public private(set) var selected = Set<Int>()
    public private(set) var replacing = false
    public private(set) var isLoading = false
    public private(set) var isRunning = false
    public private(set) var failed = false

    public internal(set) var showWords = true
    public internal(set) var words: [OcrLayerWord] = []
    public internal(set) var picked: WordRef?

    /// A word picked from the list is corrected in a box of the panel; `draft` is what the box holds.
    public internal(set) var inPanel = false
    public var draft = ""

    /// Whether a finger on a word of the page corrects it; off, a finger scrolls.
    public var touchCorrects = false

    var tab: DocumentTab?
    var host: ToolHost?
    var viewer: DocumentViewer?
    @ObservationIgnored var watch: ObservationWatch?
    @ObservationIgnored var viewWatch: ObservationWatch?
    @ObservationIgnored var shown: [Int: [OcrLayerWord]] = [:]
    @ObservationIgnored var field: OverlayField?
    @ObservationIgnored var waiting = false
    @ObservationIgnored var fieldSerial = 0
    @ObservationIgnored var touchStart: (word: WordRef, at: ViewPoint)?
    @ObservationIgnored var correctedRevision: Int?
    @ObservationIgnored private var ticket = 0
    @ObservationIgnored private let recognizer: TextRecognizer
    @ObservationIgnored private let readLanguages: () -> OcrLanguageState

    public init(recognizer: TextRecognizer? = nil, languages: @escaping () -> OcrLanguageState = OcrLanguageState.read) {
        #if canImport(Vision)
        self.recognizer = recognizer ?? VisionTextRecognizer()
        #else
        self.recognizer = recognizer ?? NoTextRecognizer()
        #endif
        readLanguages = languages
    }

    public var action: ToolAction? {
        ToolAction(L10n.t("Make searchable"), symbol: "text.viewfinder", canRun: { [self] in canRun }, run: { [self] in await run() })
    }

    var canRun: Bool { tab != nil && !isRunning && !isLoading && !language.isEmpty && !selected.isEmpty }

    public var selectedPages: [Int] { selected.sorted() }

    public var pagesSummary: String {
        if isLoading { return "" }
        if failed { return L10n.t("The pages could not be checked.") }
        let needed = rows.filter { OcrPages.wanted($0, replace: replacing) }.count
        return needed == 0 ? OcrStatusText.nothing : L10n.t("{0} of {1} pages need it.", needed, rows.count)
    }

    /// Only a page with a layer of ours can have it taken off.
    public var canRemove: Bool { !isLoading && rows.contains { selected.contains($0.page) && $0.kind == .ownLayer } }

    public var removeNote: String {
        if isLoading || canRemove { return "" }
        return rows.contains { $0.kind == .ownLayer }
            ? L10n.t("Choose pages marked Searchable above.") : L10n.t("No page has a text layer from here.")
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.host = host
        self.viewer = viewer
        fillLanguages()
        rows = []
        selected = []
        failed = false
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.fileChanged() })
        loadPages()
        attachWords()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        ticket += 1
        isLoading = false
        detachWords()
        tab = nil
        host = nil
        viewer = nil
    }

    public func setSelected(_ page: Int, _ on: Bool) {
        if on { selected.insert(page) } else { selected.remove(page) }
    }

    /// Only the pages the mode decides about move, so a choice made by hand stays.
    public func setReplacing(_ on: Bool) {
        if on == replacing { return }
        let before = replacing
        replacing = on
        for row in rows where OcrPages.wanted(row, replace: before) != OcrPages.wanted(row, replace: on) {
            setSelected(row.page, on)
        }
    }

    private func fillLanguages() {
        let state = readLanguages()
        languages = state.installed
        language = state.preferred()?.tag ?? ""
        languageNote = state.advice
    }

    private func fileChanged() {
        if tab?.revision != correctedRevision { loadPages() }
        refreshWords()
    }

    /// Triage of the file as it is; the task ends when the list is shown.
    @discardableResult
    func loadPages() -> Task<Void, Never> {
        ticket += 1
        let mine = ticket
        guard let tab, let host else { return Task {} }
        let file = tab.session.current
        let password = tab.password
        let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
        isLoading = true
        return Task { [self] in
            let kinds: [OcrPageKind]?
            do {
                kinds = try await Task.detached { try OcrPages.classify(file, password: password, certificate: certificate) }.value
            } catch {
                kinds = nil
            }
            guard ticket == mine else { return }
            failed = kinds == nil
            isLoading = false
            rows = kinds.map(OcrPages.rows) ?? []
            selected = Set(rows.filter { OcrPages.wanted($0, replace: replacing) }.map(\.page))
        }
    }

    private func run() async {
        guard let tab, let host, !language.isEmpty else { return }
        let options = OcrOptions(language: language, dpi: OcrWork.dpi, existing: replacing ? .replace : .skip, pages: selectedPages, force: true)
        let texted = rows.filter { selected.contains($0.page) && ($0.kind == .foreignLayer || $0.kind == .text) }.count
        let doubled = texted == 0 ? nil : L10n.plural(texted,
            one: "{0} chosen page already has text. Reading it adds a second layer, so search finds words twice.",
            other: "{0} chosen pages already have text. Reading them adds a second layer, so search finds words twice.")
        let go: @MainActor () -> Void = { [weak self] in
            guard let self, self.tab === tab else { return }
            Task { await self.read(tab, host, options) }
        }
        if OcrWork.cleared(tab, host, go: go, caution: doubled) { await read(tab, host, options) }
    }

    // The panel is off while the pages are read: a change to the document then would waste the run.
    private func read(_ tab: DocumentTab, _ host: ToolHost, _ options: OcrOptions) async {
        isRunning = true
        defer { isRunning = false }
        await ChangeGate.guardedAsync(host, L10n.t("Make searchable")) { [self] in
            _ = try await OcrWork.makeSearchable(tab, host, recognizer, options)
        }
    }

    public func removeLayers() {
        guard let tab, let host else { return }
        let pages = selectedPages
        let go: @MainActor () -> Void = { [weak self] in
            if self?.tab === tab { Self.remove(tab, host, pages) }
        }
        if OcrWork.cleared(tab, host, go: go) { Self.remove(tab, host, pages) }
    }

    private static func remove(_ tab: DocumentTab, _ host: ToolHost, _ pages: [Int]) {
        ChangeGate.guarded(host, L10n.t("Remove text layer")) {
            let removed = try OcrWork.remove(tab, pages)
            if removed > 0 { host.setStatus(L10n.plural(removed, one: "Removed from {0} page", other: "Removed from {0} pages")) }
        }
    }

    public func setShowWords(_ on: Bool) {
        showWords = on
        if on {
            showMarks()
        } else {
            hideMarks()
            pick(nil)
        }
    }
}
