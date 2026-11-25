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
    final class State {
        let marks = MarkList()
        var result: RedactSummary?

        // The page objects in order, to know when marks, which are kept by page number, no longer fit the pages.
        var pages: [Int]?

        // Hits in comments and fields hold offsets into text, so they only fit the revision they were found in.
        var revision = 0
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
    public private(set) var selected: UUID?

    public private(set) var marks: [MarkItem] = []
    public private(set) var canUndo = false
    public private(set) var result: RedactSummary?

    /// The file lets this opener read it but not change it, so nothing can be marked.
    public private(set) var restricted = false

    public private(set) var working = false

    var tab: DocumentTab?
    var viewer: DocumentViewer?
    var host: ToolHost?
    @ObservationIgnored private let states: TabTable<State>
    @ObservationIgnored private var state: State?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var drawTool: RedactDrawTool?
    @ObservationIgnored private var toolWatch: ObservationWatch?
    private var wantsDrawing = false
    @ObservationIgnored private var drawn: [Int: [UUID]] = [:]

    // The copy opens as a tab of its own; the panel finds that tab by its title when it is attached there.
    @ObservationIgnored private var incoming: RedactSummary?
    @ObservationIgnored private var incomingTitle = ""

    @ObservationIgnored private let fonts: FontSource?
    @ObservationIgnored private let images: ImageCodec?

    public init(fonts: FontSource? = nil, images: ImageCodec? = nil, state: TabToolState = TabToolState()) {
        self.fonts = fonts
        self.images = images
        states = state.redact
    }

    public var action: ToolAction? {
        ToolAction(L10n.t("Redact to a new file"), symbol: "rectangle.dashed", canRun: { [self] in !restricted && !marks.isEmpty },
                   run: { [self] in await apply() })
    }

    public var hasSelection: Bool { viewer?.hasSelection ?? false }

    public var canFindWords: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var drawing: Bool {
        guard wantsDrawing, let tool = drawTool, let viewer else { return false }
        return viewer.pointerTool === tool
    }

    /// Lets a drag of the selected box that is still under way end where it is, before the marks are used.
    public func handIn() -> Bool {
        drawTool?.finish()
        return true
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        states.prune()
        self.tab = tab
        self.viewer = viewer
        self.host = host
        let state = states[tab] ?? State(tab)
        states[tab] = state
        self.state = state
        if let incoming, tab.url == nil, tab.title == incomingTitle {
            state.result = incoming
            self.incoming = nil
        }
        restricted = RedactJob.refuses(tab.document)
        dropMarksOfOtherPages()
        state.marks.changed = { [weak self] in self?.marksChanged() }
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.fileChanged() })
        toolWatch = ObservationWatch(track: { _ = viewer.pointerTool }, changed: { [weak self] in self?.toolChanged() })
        marksChanged()
        result = state.result
        host.takesSelectionMarks { [weak self] in if $0 == .redact { await self?.markSelection() } }
        if host.takeSelectionMark() == .redact { Task { await markSelection() } }
    }

    public func detach() {
        host?.takesSelectionMarks(nil)
        watch?.stop()
        toolWatch?.stop()
        toolWatch = nil
        watch = nil
        state?.marks.changed = nil
        drawTool?.show(nil, nil)
        drawTool?.cancel()
        wantsDrawing = false
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
        refreshTool()
    }

    private func dropMarksOfOtherPages() {
        guard let state, let tab else { return }
        let pages = tab.document.pages.map { $0.reference.number }
        let moved = state.pages.map { $0 != pages } ?? false
        state.pages = pages
        let edited = state.revision != tab.revision
        state.revision = tab.revision
        if !moved {
            if !edited { return }
            let removed = state.marks.removeValues()
            state.marks.forget()
            if removed {
                host?.showNotice(L10n.t("Hits removed"), L10n.t("The file changed, so the hits in comments and fields no longer fit. Search again."), nil)
            }
            return
        }
        let any = !state.marks.items.isEmpty
        state.marks.clear()
        state.marks.forget()
        if !any { return }
        host?.showNotice(L10n.t("Marks removed"), L10n.t("The pages changed, so the marks no longer fit. Mark them again."), nil)
    }

    private func marksChanged() {
        guard let state else { return }
        marks = state.marks.items
        canUndo = state.marks.canUndo
        tab?.pendingMarks = marks.count
        if let selected, !marks.contains(where: { $0.id == selected }) { self.selected = nil }
        drawOverlays(redrawAll: false)
        refreshTool()
    }

    // MARK: Marking

    public func setDrawing(_ on: Bool) {
        guard viewer != nil else { return }
        wantsDrawing = on
        refreshTool()
    }

    // One tool does both: it is in the viewer while boxes are being drawn or a box is selected for editing, and not otherwise,
    // so a finger scrolls and selects text as usual. It stays the same tool when the selection moves from one box to the next.
    private func refreshTool() {
        guard let viewer else { return }
        let box = selectedBox.flatMap { $0.page < viewer.pageCount ? $0 : nil }
        if wantsDrawing || box != nil {
            let tool = drawTool ?? makeTool(viewer)
            tool.drawing = wantsDrawing
            tool.show(box, box.map { viewer.geometry($0.page) })
            if viewer.pointerTool !== tool { viewer.pointerTool = tool }
        } else if let tool = drawTool {
            tool.show(nil, nil)
            if viewer.pointerTool === tool { viewer.pointerTool = nil }
        }
    }

    private func makeTool(_ viewer: DocumentViewer) -> RedactDrawTool {
        let tool = RedactDrawTool(viewer, boxDrawn: { [weak self] page, from, to in self?.boxDrawn(page, from, to) },
                                  boxEdited: { [weak self] old, rect, geometry, resized in
                                      self?.boxEdited(old, to: rect, geometry, resized: resized) ?? false
                                  },
                                  nudge: { [weak self] move, large in self?.nudge(move, large: large) })
        drawTool = tool
        return tool
    }

    // The viewer's Select and Hand buttons, or another tool, took the pointer: nothing is drawn or framed any more.
    private func toolChanged() {
        guard let viewer, let tool = drawTool, viewer.pointerTool !== tool else { return }
        // The model took its own tool off when it wanted none: the selection (a hit row, say) is not the viewer's to clear.
        guard wantsDrawing || selectedBox != nil else { return }
        wantsDrawing = false
        selected = nil
        tool.show(nil, nil)
    }

    private func boxDrawn(_ page: Int, _ from: ViewPoint, _ to: ViewPoint) {
        guard !working, let viewer, let state else { return }
        let mark = MarkShapes.box(page, viewer.geometry(page), from: from, to: to)
        state.marks.add([MarkItem(mark, L10n.t("Box"), isBox: true)])
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
        let slow = TimedOutText.forPages(found.timedOut)
        host.setStatus(found.items.isEmpty ? slow ?? L10n.t("Nothing found.") : Self.added(state.marks.add(found.items)))
        if let notice = Self.notice(found) { host.showNotice(notice.title, notice.text, nil) }
    }

    // The timed-out pages are added to the picture notice, so neither is dropped.
    static func notice(_ found: RedactFound) -> (title: String, text: String)? {
        let slow = TimedOutText.forPages(found.timedOut)
        let more = slow != nil && !found.items.isEmpty ? " " + slow! : ""
        if found.pictures > 0 {
            return (L10n.plural(found.pictures, one: "{0} page has no text", other: "{0} pages have no text"),
                    L10n.t("Words and numbers on those pages were not searched. Draw boxes over them instead.") + more)
        }
        return more.isEmpty ? nil : (L10n.t("Some pages were not searched"), slow!)
    }

    private static func added(_ count: Int) -> String {
        count == 0 ? L10n.t("Nothing new to mark.") : L10n.plural(count, one: "{0} mark added.", other: "{0} marks added.")
    }

    // MARK: Looking the marks over

    /// Selects `item` and brings it into view. Picking the selected box again lets it go, which takes its tool off the page.
    public func jump(_ item: MarkItem) {
        if item.isBox && selected == item.id {
            selected = nil
            refreshTool()
            return
        }
        selected = item.id
        refreshTool()
        guard let viewer, item.page < viewer.pageCount else { return }
        viewer.goToPage(item.page)
        viewer.reveal(item.page, MarkShapes.place(viewer.geometry(item.page), item.mark))
    }

    public func remove(_ item: MarkItem) {
        guard let state, let host else { return }
        let pages = Self.pageNumbers(state)
        let revision = state.tab?.revision
        state.marks.remove(item)
        let after = state.marks.items.map(\.id)
        host.showNotice(L10n.t("Mark removed"), L10n.t("It is off the list."),
                        NoticeAction(L10n.t("Put it back")) { [weak self] in self?.putBack([item], in: state, pages: pages, revision: revision, after: after) })
    }

    public func removeSelected() {
        if let item = marks.first(where: { $0.id == selected }) { remove(item) }
    }

    public func clearMarks() {
        guard let state, let host else { return }
        let removed = state.marks.items
        let pages = Self.pageNumbers(state)
        let revision = state.tab?.revision
        state.marks.clear()
        let after = state.marks.items.map(\.id)
        host.showNotice(L10n.plural(removed.count, one: "{0} mark removed", other: "{0} marks removed"), L10n.t("The list is empty now."),
                        NoticeAction(L10n.t("Put them back")) { [weak self] in self?.putBack(removed, in: state, pages: pages, revision: revision, after: after) })
    }

    public func undo() {
        if working { return }
        state?.marks.undo()
    }

    // MARK: Editing a box

    /// The box of the list that is selected; value marks and whole selections are not boxes and are never edited.
    var selectedBox: MarkItem? {
        marks.first { $0.id == selected && $0.isBox }
    }

    public var canNudge: Bool {
        guard let viewer, let box = selectedBox else { return false }
        return box.page < viewer.pageCount
    }

    /// Moves or resizes the selected box by a step of the keyboard (1 point, 10 when `large`). Each step is in the list at
    /// once; a run of them is one step of Undo.
    public func nudge(_ move: BoxMove, large: Bool = false) {
        guard !working, let viewer, let box = selectedBox, box.page < viewer.pageCount else { return }
        let geometry = viewer.geometry(box.page)
        let rect = MarkShapes.place(geometry, box.mark)
        let (arrow, resize) = move.keys
        let moved = RedactDrawTool.nudge(rect, arrow, resize: resize, large: large, viewer.pageSize(box.page))
        if moved == rect { return }
        boxEdited(box, to: moved, geometry, resized: resize, coalesce: true)
    }

    // The geometry is the one the rectangle was worked out in, which the viewer may no longer have by the time a drag ends.
    @discardableResult
    func boxEdited(_ old: MarkItem, to rect: ViewRect, _ geometry: PageGeometry, resized: Bool, coalesce: Bool = false) -> Bool {
        let mark = MarkShapes.box(old.page, geometry, from: rect.topLeft, to: ViewPoint(rect.right, rect.bottom))
        guard replace(old, MarkItem(mark, old.label, isBox: true, row: old.row), coalesce: coalesce) else { return false }
        host?.setStatus(resized ? L10n.t("Box resized.") : L10n.t("Box moved."))
        return true
    }

    // The new item has an id of its own; it is selected before the list tells of the change, which would let the selection go.
    @discardableResult
    func replace(_ old: MarkItem, _ new: MarkItem, coalesce: Bool = false) -> Bool {
        guard !working, let state, marks.contains(where: { $0.id == old.id }) else { return false }
        selected = new.id
        state.marks.replace(old, new, coalesce: coalesce)
        return true
    }

    private static func pageNumbers(_ state: State) -> [Int]? {
        state.tab?.document.pages.map { $0.reference.number }
    }

    // The notice outlives later edits, and a moved box keeps its row, so putting an old item back into a changed list would
    // show one row twice. It only acts while the list is as the removal left it, as on Windows.
    // Marks are placed on pages, so they only fit while the page list is what it was when they were removed. Hits in comments and fields also hang on text, which any edit may have changed.
    private func putBack(_ items: [MarkItem], in state: State, pages: [Int]?, revision: Int?, after: [UUID]) {
        if Self.pageNumbers(state) != pages {
            host?.showNotice(L10n.t("Marks removed"), L10n.t("The pages changed, so the marks no longer fit. Mark them again."), nil)
            return
        }
        // A file change forgets the history, so there may be nothing to undo and no Undo button to point to.
        if state.marks.items.map(\.id) != after || !state.marks.canUndo {
            host?.setStatus(state.marks.canUndo ? L10n.t("The marks changed since. Use Undo in the list.") : L10n.t("The marks changed since."))
            return
        }
        let fits = state.tab?.revision == revision ? items : items.filter { $0.value == nil }
        if fits.isEmpty {
            host?.showNotice(L10n.t("Hits removed"), L10n.t("The file changed, so the hits in comments and fields no longer fit. Search again."), nil)
        } else {
            state.marks.add(fits)
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
        state.marks.forget()
        tab.pendingMarks = 0
        let summary = RedactSummary.of(made, flattenedAll: settings.flattenAll)
        incoming = summary
        incomingTitle = L10n.t("{0} (redacted).pdf", (tab.title as NSString).deletingPathExtension)
        await host.openNew(made.bytes, title: incomingTitle, password: nil, certificate: nil)
        host.setStatus(summary.clean ? L10n.t("Redacted copy opened.") : L10n.t("Redacted copy has problems."))
        if encrypted { host.showNotice(L10n.t("The copy has no password"), L10n.t("Protect it before you share it."), nil) }
    }
}

/// The ways a selected box is moved or resized from the keyboard or by a screen reader. Wider and narrower move the right
/// edge, taller and shorter the bottom edge.
public enum BoxMove: CaseIterable {
    case left, right, up, down, wider, narrower, taller, shorter

    var keys: (RedactDrawTool.Arrow, resize: Bool) {
        switch self {
        case .left: (.left, false)
        case .right: (.right, false)
        case .up: (.up, false)
        case .down: (.down, false)
        case .wider: (.right, true)
        case .narrower: (.left, true)
        case .taller: (.down, true)
        case .shorter: (.up, true)
        }
    }
}
