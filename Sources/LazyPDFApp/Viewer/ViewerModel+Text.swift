import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Viewer/PageViewer.Text.cs: text read for a revision, selecting it, and the shapes of the selection
// and the search hits for the views to draw. Copying is the view's, which owns the pasteboard.

/// The shapes to lay over a page, each a four-cornered polygon in page space.
public struct PageHighlights {
    public var hits: [[ViewPoint]] = []
    public var currentHit: [[ViewPoint]] = []
    public var selection: [[ViewPoint]] = []
}

extension ViewerModel {
    public var hasSelection: Bool { !selected.isEmpty }

    // A file opened with a certificate is read from a decrypted copy, as the page renderer does. The key stays with the
    // platform, so the copy is written from the open document, and the caller runs the returned closure off the main actor.
    func readable(_ tab: DocumentTab) -> () -> (bytes: [UInt8], password: String?) {
        if tab.certificate == nil {
            let plain = (bytes: tab.session.current, password: tab.password)
            return { plain }
        }
        let document = tab.document
        return { ((try? PdfRewriter(document, PdfSaveOptions()).run()) ?? [], nil) }
    }

    // The file changed or another one is shown: what was read is stale.
    func resetText() {
        textTask = nil
        source = nil
        links.removeAll()
        selectionShapes.removeAll()
        hitShapes.removeAll()
        selected.clear()
    }

    func textSource() -> Task<TextSource?, Never> {
        guard let tab else { return Task<TextSource?, Never> { nil } }
        if let textTask { return textTask }
        let read = readable(tab)
        let task = Task<TextSource?, Never>.detached {
            let (data, password) = read()
            return await TextSource.open(data, password: password)
        }
        textTask = task
        Task { [weak self] in
            let opened = await task.value
            guard let self, self.textTask == task else { return }
            self.source = opened
            self.onRedraw?()
        }
        return task
    }

    func preloadText() {
        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            for page in self.visiblePages.prefix(8) { await self.loadPage(page) }
        }
    }

    func loadPage(_ page: Int) async {
        if await text(page) != nil { onRedraw?() }
    }

    public func text(_ page: Int) async -> TextPage? {
        await textSource().value?.get(page)
    }

    /// The text of a page for a screen reader, if it has been read.
    public func pageText(_ page: Int) -> String? {
        source?.peek(page)?.text
    }

    func isOverText(_ page: Int, _ point: ViewPoint) -> Bool {
        guard let text = source?.peek(page) else { return false }
        let (x, y) = geometry(page).toUser(point.x, point.y)
        return text.hitTest(x, y, maxDistance: 2) != nil
    }

    func link(at page: Int, _ point: ViewPoint) -> PdfLink? {
        guard let tab else { return nil }
        guard page >= 0, page < tab.document.pages.count else { return nil }
        if links[page] == nil { links[page] = PdfLinks.read(tab.document, tab.document.pages[page]) }
        guard let found = links[page], !found.isEmpty else { return nil }
        let (x, y) = geometry(page).toUser(point.x, point.y)
        return found.first { x >= $0.rect.left && x <= $0.rect.right && y >= $0.rect.bottom && y <= $0.rect.top }
    }

    func selectionChanged() {
        selectionShapes.removeAll()
        onRedraw?()
    }

    func beginSelection(_ at: ViewPoint, clicks: Int, extend wanted: Bool) {
        pressTicket += 1
        let ticket = pressTicket
        anchorWaiting = nil
        multi = nil
        guard let hit = state.hit(at, nearest: true) else { return }
        dragPage = hit.page
        let extend = wanted && !selected.isEmpty
        guard let text = source?.peek(hit.page) else {
            if clicks >= 2 {
                let sameTab = tab
                Task {
                    await loadPage(hit.page)
                    guard pressTicket == ticket, tab === sameTab, let text = source?.peek(hit.page) else { return }
                    selectUnit(hit, text, clicks)
                }
                return
            }
            Task { await loadPage(hit.page) }
            if !extend {
                selected.clear()
                anchorWaiting = PagePoint(hit.page, hit.point)
            }
            return
        }
        if clicks >= 2 {
            selectUnit(hit, text, clicks)
            return
        }
        let (x, y) = geometry(hit.page).toUser(hit.point.x, hit.point.y)
        let caret = Caret(hit.page, text.caretAt(x, y))
        if extend { selected.extend(caret) } else { selected.set(caret, caret) }
    }

    private func selectUnit(_ hit: (page: Int, point: ViewPoint), _ text: TextPage, _ clicks: Int) {
        let (x, y) = geometry(hit.page).toUser(hit.point.x, hit.point.y)
        let chosen = clicks == 2 ? TextSelection.wordAt(text, x, y) : TextSelection.lineAt(text, x, y)
        guard let first = chosen.ranges.first, let last = chosen.ranges.last else {
            selected.clear()
            return
        }
        let (from, to) = (Caret(hit.page, first.start), Caret(hit.page, last.end))
        selected.set(from, to)
        multi = (from, to, clicks)
    }

    func dragSelection(_ at: ViewPoint) {
        guard moved, let hit = state.hit(at, nearest: true) else { return }
        guard let text = source?.peek(hit.page) else {
            Task { await loadPage(hit.page) }
            return
        }
        if let waiting = anchorWaiting {
            // The press came before the page's text did; the selection starts where the press was.
            guard let anchorText = source?.peek(waiting.page) else {
                Task { await loadPage(waiting.page) }
                return
            }
            let (ax, ay) = geometry(waiting.page).toUser(waiting.point.x, waiting.point.y)
            let anchor = Caret(waiting.page, anchorText.caretAt(ax, ay))
            selected.set(anchor, anchor)
            anchorWaiting = nil
        }
        let (x, y) = geometry(hit.page).toUser(hit.point.x, hit.point.y)
        if let multi {
            // After a double or triple click the selection grows by whole words or lines.
            let unit = multi.clicks == 2 ? TextSelection.wordAt(text, x, y) : TextSelection.lineAt(text, x, y)
            guard let first = unit.ranges.first, let last = unit.ranges.last else { return }
            let (from, to) = (Caret(hit.page, first.start), Caret(hit.page, last.end))
            if from < multi.start { selected.set(multi.end, from) } else { selected.set(multi.start, to) }
            return
        }
        selected.extend(Caret(hit.page, text.caretAt(x, y)))
    }

    public func selectAll() {
        guard tab != nil else { return }
        selected.selectAll(state.pageCount)
        for page in visiblePages { Task { await loadPage(page) } }
    }

    public func clearSelection() {
        selected.clear()
    }

    /// Selects the word under a point, as a long press does.
    public func selectWord(at point: ViewPoint) {
        pointerDown(point, clicks: 2)
        pointerUp(point)
    }

    /// Where the two handles of the selection stand, in view space: the lower left of its first line and the lower right of its last.
    public func selectionHandles() -> (start: ViewPoint, end: ViewPoint)? {
        guard !selected.isEmpty,
              let first = highlights(of: selected.start.page).selection.first,
              let last = highlights(of: selected.end.page).selection.last,
              let from = pageToView(selected.start.page), let to = pageToView(selected.end.page) else { return nil }
        let start = ViewPoint(first.map(\.x).min() ?? 0, first.map(\.y).max() ?? 0)
        let end = ViewPoint(last.map(\.x).max() ?? 0, last.map(\.y).max() ?? 0)
        return (from.transform(start), to.transform(end))
    }

    /// True for the start handle and false for the end handle when one is within `radius` of the point, the nearer of the two.
    public func handle(at point: ViewPoint, within radius: Double) -> Bool? {
        guard let handles = selectionHandles() else { return nil }
        // Measured to the middle of the stem, which is 14 points long, so a touch on the ball counts as well as one on the line.
        let toStart = hypot(point.x - handles.start.x, point.y - (handles.start.y - 7))
        let toEnd = hypot(point.x - handles.end.x, point.y - (handles.end.y - 7))
        if Swift.min(toStart, toEnd) > radius { return nil }
        return toStart < toEnd
    }

    /// Takes hold of a handle: the other end stays where it is and the dragged one follows the pointer, which keeps its distance
    /// from the middle of the handle's line, so the end does not jump to where the finger lies.
    public func beginHandleDrag(start: Bool, at: ViewPoint) {
        let page = start ? selected.start.page : selected.end.page
        let quad = start ? highlights(of: page).selection.first : highlights(of: page).selection.last
        guard !selected.isEmpty, let quad, let matrix = pageToView(page) else { return }
        let x = start ? quad.map(\.x).min() : quad.map(\.x).max()
        let middle = matrix.transform(ViewPoint(x ?? 0, ((quad.map(\.y).min() ?? 0) + (quad.map(\.y).max() ?? 0)) / 2))
        grip = ViewPoint(middle.x - at.x, middle.y - at.y)
        selected.set(start ? selected.end : selected.start, start ? selected.start : selected.end)
        anchorWaiting = nil
        multi = nil
        drag = .select
        down = at
        last = at
        moved = true
        touching = true
        startAutoScroll()
    }

    // Moves the focus end of the selection as a text caret would. False for a key that is not one of its.
    func extendSelection(_ key: ViewerKey, big: Bool) -> Bool {
        let focus = selected.focus
        guard let text = source?.peek(focus.page) else { return false }
        let count = text.chars.count
        let index = Swift.min(focus.index, count)
        let last = state.pageCount - 1
        let next: Caret?
        switch key {
        case .left where big: next = index > 0 ? Caret(focus.page, Self.previousWord(text, index)) : focus.page > 0 ? Caret(focus.page - 1, Int.max) : nil
        case .right where big: next = index < count ? Caret(focus.page, Self.nextWord(text, index)) : focus.page < last ? Caret(focus.page + 1, 0) : nil
        case .left: next = index > 0 ? Caret(focus.page, index - 1) : focus.page > 0 ? Caret(focus.page - 1, Int.max) : nil
        case .right: next = index < count ? Caret(focus.page, index + 1) : focus.page < last ? Caret(focus.page + 1, 0) : nil
        case .up: next = Self.moveLine(focus.page, text, index, -1)
        case .down: next = Self.moveLine(focus.page, text, index, 1)
        case .home where big: next = Caret(0, 0)
        case .end where big: next = Caret(last, Int.max)
        case .home: next = Caret(focus.page, Self.lineEdge(text, index, start: true))
        case .end: next = Caret(focus.page, Self.lineEdge(text, index, start: false))
        default: return false
        }
        if let next {
            selected.extend(next)
            revealCaret(next)
        }
        return true
    }

    private static func nextWord(_ text: TextPage, _ index: Int) -> Int {
        text.words.first { $0.range.start > index }?.range.start ?? text.chars.count
    }

    private static func previousWord(_ text: TextPage, _ index: Int) -> Int {
        text.words.last { $0.range.start < index }?.range.start ?? 0
    }

    private static func lineOf(_ text: TextPage, _ index: Int) -> Int {
        text.chars[Swift.min(Swift.max(index, 0), text.chars.count - 1)].line
    }

    private static func lineEdge(_ text: TextPage, _ index: Int, start: Bool) -> Int {
        if text.chars.isEmpty { return 0 }
        let range = text.lines[lineOf(text, index == text.chars.count ? index - 1 : index)].range
        return start ? range.start : range.end
    }

    private static func moveLine(_ page: Int, _ text: TextPage, _ index: Int, _ step: Int) -> Caret? {
        if text.chars.isEmpty { return nil }
        let line = lineOf(text, index == text.chars.count ? index - 1 : index) + step
        if line < 0 { return Caret(page, 0) }
        if line >= text.lines.count { return Caret(page, text.chars.count) }
        let x = text.chars[Swift.min(index, text.chars.count - 1)].quad.center.x
        let y = text.lines[line].quad.center.y
        return Caret(page, text.caretAt(x, y))
    }

    // The rectangle of page space that holds the quads (user space).
    func pageBounds(_ page: Int, _ quads: [TextQuad]) -> ViewRect {
        let geometry = geometry(page)
        var left = Double.infinity, top = Double.infinity, right = -Double.infinity, bottom = -Double.infinity
        for quad in quads {
            let box = quad.bounds
            for corner in [geometry.toDisplay(box.left, box.bottom), geometry.toDisplay(box.right, box.top)] {
                left = Swift.min(left, corner.x)
                right = Swift.max(right, corner.x)
                top = Swift.min(top, corner.y)
                bottom = Swift.max(bottom, corner.y)
            }
        }
        return left > right ? .empty : ViewRect(left, top, right - left, bottom - top)
    }

    // Scrolls to the character the caret is at, if it is out of view.
    private func revealCaret(_ caret: Caret) {
        guard let text = source?.peek(caret.page), !text.chars.isEmpty else { return }
        let i = Swift.min(Swift.max(caret.index, 0), text.chars.count - 1)
        let area = pageBounds(caret.page, text.quads(LazyPDFKit.TextRange(i, i + 1)))
        if !area.isEmpty { reveal(caret.page, area) }
    }

    /// The selected text, page by page.
    public func selection() async -> [SelectedRun] {
        var runs: [SelectedRun] = []
        if selected.isEmpty { return runs }
        for page in selected.start.page...selected.end.page {
            guard let text = await text(page), let range = selected.on(page, text.chars.count) else { continue }
            runs.append(SelectedRun(page: page, range: range, text: text.getText(range), quads: text.quads(range)))
        }
        return runs
    }

    /// False when the file was opened without the right to copy content out.
    public var canCopy: Bool { tab.map { Exporter.allowed($0.document) } ?? true }

    /// What Copy puts on the pasteboard; nil when nothing is selected or the file forbids copying.
    public func selectedText() async -> String? {
        if !selected.isEmpty && !canCopy {
            tell(L10n.t("The owner of this file does not allow copying."))
            return nil
        }
        let runs = await selection()
        return runs.isEmpty ? nil : runs.map(\.text).joined(separator: "\n")
    }

    func selectedOnOnePage() -> String? {
        let page = selected.start.page
        guard let text = source?.peek(page), let range = selected.on(page, text.chars.count) else { return nil }
        return text.getText(range)
    }

    /// The search hits and the selection on a page. A page whose text has not been read yet shows no selection until it is.
    public func highlights(of page: Int) -> PageHighlights {
        var result = PageHighlights()
        if !search.hits.isEmpty {
            let shapes = hitShapes[page] ?? makeHitShapes(page)
            hitShapes[page] = shapes
            (result.hits, result.currentHit) = shapes
        }
        if selected.covers(page) {
            if let text = source?.peek(page) {
                if selectionShapes[page] == nil {
                    selectionShapes[page] = selected.on(page, text.chars.count).map { outline(page, text.quads($0)) } ?? []
                }
                result.selection = selectionShapes[page] ?? []
            } else {
                Task { await loadPage(page) }
            }
        }
        return result
    }

    private func makeHitShapes(_ page: Int) -> (others: [[ViewPoint]], current: [[ViewPoint]]) {
        var others: [TextQuad] = [], current: [TextQuad] = []
        for (i, hit) in search.hits.enumerated() where hit.page == page {
            if i == search.current { current += hit.match.quads } else { others += hit.match.quads }
        }
        return (outline(page, others), outline(page, current))
    }

    // The quads (user space) as polygons in page space.
    private func outline(_ page: Int, _ quads: [TextQuad]) -> [[ViewPoint]] {
        let geometry = geometry(page)
        return quads.map { q in
            [geometry.toDisplay(q.x0, q.y0), geometry.toDisplay(q.x1, q.y1), geometry.toDisplay(q.x2, q.y2), geometry.toDisplay(q.x3, q.y3)]
                .map { ViewPoint($0.x, $0.y) }
        }
    }
}
