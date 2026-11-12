import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Redact/RedactPanel.xaml.cs and its Apply, Marking and Review parts: marks what is to go by
// drawing, by selecting, by searching and by shape, lets the marks be looked over, and writes the redacted copy as a new file.
// The marks live here, per document, until the copy is made.

@MainActor
@Observable
public final class RedactModel: ToolPanelModel {
    // What the panel remembers of a document while another tool or tab is in front.
    private final class State {
        let marks = MarkList()
        var result: RedactSummary?

        // The page objects in order, to know when marks, which are kept by page number, no longer fit the pages.
        var pages: [Int]?
        weak var tab: DocumentTab?

        init(_ tab: DocumentTab) {
            self.tab = tab
        }
    }

    public var query = ""
    public var matchCase = false
    public var wholeWord = false
    public var kindIndex = 0
    public var coverIndex = 0
    public var overlayText = ""
    public var flattenAll = false
    public var selected: UUID?

    public private(set) var marks: [MarkItem] = []
    public private(set) var result: RedactSummary?

    /// The file lets this opener read it but not change it, so nothing can be marked.
    public private(set) var restricted = false

    public private(set) var working = false

    var tab: DocumentTab?
    var viewer: DocumentViewer?
    var host: ToolHost?
    @ObservationIgnored private var states: [UUID: State] = [:]
    @ObservationIgnored private var state: State?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var drawTool: RedactDrawTool?
    @ObservationIgnored private var drawn: [Int: [UUID]] = [:]

    // The copy opens as a tab of its own; the panel finds that tab by its title when it is attached there.
    @ObservationIgnored private var incoming: RedactSummary?
    @ObservationIgnored private var incomingTitle = ""

    @ObservationIgnored private let fonts: FontSource?
    @ObservationIgnored private let images: ImageCodec?

    public init(fonts: FontSource? = nil, images: ImageCodec? = nil) {
        self.fonts = fonts
        self.images = images
    }

    public var action: ToolAction? {
        ToolAction(L10n.t("Redact to a new file"), symbol: "rectangle.dashed", canRun: { [self] in !restricted && !marks.isEmpty },
                   run: { [self] in await apply() })
    }

    public var hasSelection: Bool { viewer?.hasSelection ?? false }

    public var canFindWords: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var drawing: Bool {
        guard let tool = drawTool, let viewer else { return false }
        return viewer.pointerTool === tool
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        states = states.filter { $0.value.tab.map { !$0.isDisposed } ?? false }
        self.tab = tab
        self.viewer = viewer
        self.host = host
        let state = states[tab.id] ?? State(tab)
        states[tab.id] = state
        self.state = state
        if let incoming, tab.url == nil, tab.title == incomingTitle {
            state.result = incoming
            self.incoming = nil
        }
        restricted = RedactJob.refuses(tab.document)
        dropMarksOfOtherPages()
        state.marks.changed = { [weak self] in self?.marksChanged() }
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.fileChanged() })
        marksChanged()
        result = state.result
        host.takesSelectionMarks { [weak self] in if $0 == .redact { await self?.markSelection() } }
        if host.takeSelectionMark() == .redact { Task { await markSelection() } }
    }

    public func detach() {
        host?.takesSelectionMarks(nil)
        watch?.stop()
        watch = nil
        state?.marks.changed = nil
        drawTool?.cancel()
        drawTool = nil
        drawn = [:]
        marks = []
        result = nil
        selected = nil
        state = nil
        tab = nil
        viewer = nil
        host = nil
    }

    private func fileChanged() {
        dropMarksOfOtherPages()
        drawOverlays(redrawAll: true)
    }

    private func dropMarksOfOtherPages() {
        guard let state, let tab else { return }
        let pages = tab.document.pages.map { $0.reference.number }
        let moved = state.pages.map { $0 != pages } ?? false
        state.pages = pages
        if !moved || state.marks.items.isEmpty { return }
        state.marks.clear()
        host?.showNotice(L10n.t("Marks removed"), L10n.t("The pages changed, so the marks no longer fit. Mark them again."), nil)
    }

    private func marksChanged() {
        guard let state else { return }
        marks = state.marks.items
        tab?.pendingMarks = marks.count
        if let selected, !marks.contains(where: { $0.id == selected }) { self.selected = nil }
        drawOverlays(redrawAll: false)
    }

    // MARK: Marking

    public func setDrawing(_ on: Bool) {
        guard let viewer else { return }
        if on {
            let tool = RedactDrawTool(viewer) { [weak self] page, from, to in self?.boxDrawn(page, from, to) }
            drawTool = tool
            viewer.pointerTool = tool
        } else if let tool = drawTool, viewer.pointerTool === tool {
            viewer.pointerTool = nil
        }
    }

    private func boxDrawn(_ page: Int, _ from: ViewPoint, _ to: ViewPoint) {
        guard let viewer, let state else { return }
        let mark = MarkShapes.box(page, viewer.geometry(page), from: from, to: to)
        state.marks.add([MarkItem(mark, L10n.t("Box"))])
    }

    public func markSelection() async {
        guard let viewer, let state, let host, !restricted else { return }
        let runs = await viewer.selection()
        let items = runs.filter { !$0.quads.isEmpty }.map { MarkItem(RedactionMark($0.page, $0.quads), RedactJob.clip($0.text)) }
        let added = state.marks.add(items)
        if added > 0 { viewer.clearSelection() }
        host.setStatus(Self.added(added))
    }

    public func markWords() async {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty { return }
        let (matchCase, wholeWord) = (self.matchCase, self.wholeWord)
        await search { document, token in try RedactJob.find(document, words: words, matchCase: matchCase, wholeWord: wholeWord, token: token) }
    }

    public func markKind() async {
        let kinds = RedactDataKind.all
        let kind = kinds[min(max(kindIndex, 0), kinds.count - 1)]
        await search { document, token in try RedactJob.find(document, kind, token: token) }
    }

    private func search(_ find: @escaping @Sendable (PdfDocument, CancelToken) throws -> RedactFound) async {
        if working { return }
        guard let tab, let host, let state else { return }
        let file = tab.session.current
        let password = tab.password
        let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
        var found: RedactFound?
        working = true
        do {
            try await host.runBusy(L10n.t("Searching")) { token in
                found = try await ToolDocuments.run(token) {
                    try find(RedactJob.open(file, password: password, certificate: certificate), token)
                }
            }
        } catch {
            working = false
            host.showProblem(Problem(L10n.t("Search failed"), L10n.t("The file could not be searched. Close it and open it again.")))
            return
        }
        working = false
        guard let found else { return }
        host.setStatus(found.items.isEmpty ? L10n.t("Nothing found.") : Self.added(state.marks.add(found.items)))
        if found.pictures > 0 {
            host.showNotice(L10n.plural(found.pictures, one: "{0} page has no text", other: "{0} pages have no text"),
                            L10n.t("Words and numbers on those pages were not searched. Draw boxes over them instead."), nil)
        }
    }

    private static func added(_ count: Int) -> String {
        count == 0 ? L10n.t("Nothing new to mark.") : L10n.plural(count, one: "{0} mark added.", other: "{0} marks added.")
    }

    // MARK: Looking the marks over

    public func jump(_ item: MarkItem) {
        selected = item.id
        guard let viewer, item.page < viewer.pageCount else { return }
        viewer.goToPage(item.page)
        viewer.reveal(item.page, MarkShapes.place(viewer.geometry(item.page), item.mark))
    }

    public func remove(_ item: MarkItem) {
        guard let state, let host else { return }
        let pages = Self.pageNumbers(state)
        state.marks.remove(item)
        host.showNotice(L10n.t("Mark removed"), L10n.t("It is off the list."),
                        NoticeAction(L10n.t("Put it back")) { [weak self] in self?.putBack([item], in: state, pages: pages) })
    }

    public func removeSelected() {
        if let item = marks.first(where: { $0.id == selected }) { remove(item) }
    }

    public func clearMarks() {
        guard let state, let host else { return }
        let removed = state.marks.items
        let pages = Self.pageNumbers(state)
        state.marks.clear()
        host.showNotice(L10n.plural(removed.count, one: "{0} mark removed", other: "{0} marks removed"), L10n.t("The list is empty now."),
                        NoticeAction(L10n.t("Put them back")) { [weak self] in self?.putBack(removed, in: state, pages: pages) })
    }

    private static func pageNumbers(_ state: State) -> [Int]? {
        state.tab?.document.pages.map { $0.reference.number }
    }

    // Marks are placed on pages, so they only fit while the page list is what it was when they were removed.
    private func putBack(_ items: [MarkItem], in state: State, pages: [Int]?) {
        if Self.pageNumbers(state) == pages {
            state.marks.add(items)
        } else {
            host?.showNotice(L10n.t("Marks removed"), L10n.t("The pages changed, so the marks no longer fit. Mark them again."), nil)
        }
    }

    // The viewer may have rebuilt its layers (redrawAll); otherwise only the pages whose marks changed are drawn again.
    private func drawOverlays(redrawAll: Bool) {
        guard let viewer, let state else { return }
        if redrawAll {
            for page in Array(drawn.keys) { erase(page) }
        }
        let byPage = Dictionary(grouping: state.marks.items.filter { $0.page < viewer.pageCount }, by: \.page)
        for page in Array(drawn.keys) where byPage[page] == nil { erase(page) }
        for (page, items) in byPage {
            let ids = items.map(\.id)
            if drawn[page] == ids { continue }
            erase(page)
            let overlay = viewer.overlay(page)
            let geometry = viewer.geometry(page)
            var n = 0
            for quad in items.flatMap({ $0.mark.quads }) {
                overlay.set(OverlayItem("redact.mark.\(n)", .path(MarkShapes.outline(geometry, quad), closed: true), style: Self.markStyle))
                n += 1
            }
            drawn[page] = ids
        }
    }

    private static let markStyle = OverlayStyle(stroke: RedactDrawTool.colour, fill: RedactDrawTool.colour.opacity(0.33), lineWidth: 1)

    private func erase(_ page: Int) {
        viewer?.overlay(page).remove(prefix: "redact.mark.")
        drawn[page] = nil
    }

    // MARK: Making the copy

    private func apply() async {
        if working { return }
        guard let tab, let host, let state else { return }
        await tab.whenDrawn()
        let items = state.marks.items.filter { $0.value == nil }.map(\.mark)
        let values = state.marks.items.compactMap(\.value)
        let covers = RedactCover.all
        let settings = RedactSettings(cover: covers[min(max(coverIndex, 0), covers.count - 1)], overlayText: overlayText, flattenAll: flattenAll)
        let file = tab.session.current
        let revision = tab.revision
        let encrypted = tab.document.isEncrypted
        let password = tab.password
        let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
        let renderer = tab.renderer
        let (fonts, images) = (self.fonts, self.images)
        let stale = Problem(L10n.t("Not redacted"), L10n.t("The file changed meanwhile. Try again."))
        var made: RedactionResult?
        working = true
        do {
            try await host.runBusy(L10n.t("Redacting")) { token in
                made = try await ToolDocuments.run(token) {
                    try RedactJob.apply(file, password: password, certificate: certificate, marks: items, values: values, settings: settings,
                                        renderer: renderer, fonts: fonts, images: images, token: token)
                }
            }
        } catch {
            working = false
            host.showProblem(tab.revision != revision ? stale : RedactJob.failed(error))
            return
        }
        working = false
        guard let made else { return }
        if tab.revision != revision {
            host.showProblem(stale)
            return
        }

        // The marks are done with once the copy exists; the panel may be detached by now, so the count is set here too.
        state.marks.clear()
        tab.pendingMarks = 0
        let summary = RedactSummary.of(made, flattenedAll: settings.flattenAll)
        incoming = summary
        incomingTitle = L10n.t("{0} (redacted).pdf", (tab.title as NSString).deletingPathExtension)
        await host.openNew(made.bytes, title: incomingTitle, password: nil, certificate: nil)
        host.setStatus(summary.clean ? L10n.t("Redacted copy opened.") : L10n.t("Redacted copy has problems."))
        if encrypted { host.showNotice(L10n.t("The copy has no password"), L10n.t("Protect it before you share it."), nil) }
    }
}
