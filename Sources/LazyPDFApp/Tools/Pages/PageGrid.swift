import Foundation
import Observation
import LazyPDFKit

// The grid both the Pages panel and the organize view show (the ListBox `Thumbs` of PagesPanel.xaml.cs and
// OrganizeView.xaml.cs, with PageDrag.cs): a cell for every page of the tab, the pages chosen, and the marks of a drag. The edits
// each of them offers are in PageGrid+Edit.swift.

@MainActor
@Observable
public final class PageGrid {
    public private(set) var cells: [PageCell] = []
    public private(set) var selected = Set<Int>()
    public private(set) var isSigned = false
    public private(set) var boxWidth: Double
    public private(set) var boxHeight: Double

    /// The pages a drag in progress carries.
    @ObservationIgnored public var dragging: [Int] = []

    /// Called when the person chooses pages, not when an edit puts the choice back.
    @ObservationIgnored public var onSelect: (() -> Void)?

    /// Called after the cells were made again.
    @ObservationIgnored public var onRebuild: (() -> Void)?

    /// The page a Shift click counts from.
    @ObservationIgnored private var anchor: Int?

    @ObservationIgnored var tab: DocumentTab?
    @ObservationIgnored var host: ToolHost?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var builtDrawn = -1
    @ObservationIgnored private var sizes: [(width: Double, height: Double)] = []
    @ObservationIgnored private var marked: PageCell?

    public init(boxWidth: Double, boxHeight: Double) {
        self.boxWidth = boxWidth
        self.boxHeight = boxHeight
    }

    public func attach(_ tab: DocumentTab, _ host: ToolHost) {
        self.tab = tab
        self.host = host
        watch = ObservationWatch(track: { _ = tab.drawn }, changed: { [weak self] in
            guard let self, let tab = self.tab, tab.drawn != self.builtDrawn else { return }
            self.rebuild(select: nil)
            self.onRebuild?()
        })
        rebuild(select: nil)
    }

    public func detach() {
        watch?.stop()
        watch = nil
        for cell in cells { cell.release() }
        cells = []
        selected = []
        sizes = []
        marked = nil
        tab = nil
        host = nil
    }

    /// Makes a cell for every page of the file as it is now. Pages named in `select` that are still there stay chosen.
    public func rebuild(select: [Int]?) {
        for cell in cells { cell.release() }
        marked = nil
        dragging = []
        anchor = nil
        guard let tab else { return }
        let document = tab.document
        let labels = PdfPageLabels.labels(document)
        let renderer = tab.canDraw ? tab.renderer : nil
        sizes = document.pages.map { page in
            let shown = PageGeometry(page)
            return (width: shown.width, height: shown.height)
        }
        cells = sizes.indices.map { page in
            let fit = self.fit(page)
            let label = page < labels.count && !labels[page].isEmpty ? labels[page] : String(page + 1)
            return PageCell(index: page, label: label, width: fit.width, height: fit.height, scale: fit.scale, renderer: renderer)
        }
        selected = Set((select ?? []).filter { $0 >= 0 && $0 < cells.count })
        isSigned = document.isSigned
        builtDrawn = tab.drawn
    }

    /// Changes the box a page picture fits in; the pictures keep their size until `sharpen`.
    public func setBox(width: Double, height: Double) {
        boxWidth = width
        boxHeight = height
        for (page, cell) in cells.enumerated() {
            let fit = self.fit(page)
            cell.refit(width: fit.width, height: fit.height, scale: fit.scale)
        }
    }

    public func sharpen() {
        for cell in cells { cell.sharpen() }
    }

    private func fit(_ page: Int) -> (width: Double, height: Double, scale: Double) {
        let size = sizes[page]
        let scale = min(boxWidth / max(size.width, 1), boxHeight / max(size.height, 1))
        return (max((size.width * scale).rounded(), 4), max((size.height * scale).rounded(), 4), scale)
    }

    public var selection: [Int] { selected.sorted() }

    /// The pages a job covers: the choice, else every page.
    public var selectedOrAll: [Int] {
        selected.isEmpty ? Array(cells.indices) : selection
    }

    public var summary: String {
        selected.isEmpty ? L10n.plural(cells.count, one: "{0} page", other: "{0} pages")
            : L10n.t("{0} of {1} selected", selected.count, cells.count)
    }

    /// Puts the choice back after an edit, without calling `onSelect`.
    public func select(_ pages: [Int]) {
        selected = Set(pages.filter { $0 >= 0 && $0 < cells.count })
    }

    /// The pages a menu on `page` is about: the choice if the page is in it, else the page alone.
    public func target(_ page: Int) -> [Int] {
        selected.contains(page) ? selection : [page]
    }

    public func toggle(_ page: Int) {
        guard page >= 0, page < cells.count else { return }
        if selected.contains(page) { selected.remove(page) } else { selected.insert(page) }
        anchor = page
        onSelect?()
    }

    /// A plain click on a Mac: this page alone is chosen.
    public func choose(_ page: Int) {
        guard page >= 0, page < cells.count else { return }
        selected = [page]
        anchor = page
        onSelect?()
    }

    /// Shift click: every page from the one last clicked to `page` is chosen.
    public func extend(to page: Int) {
        guard page >= 0, page < cells.count else { return }
        let from = anchor.flatMap { $0 < cells.count ? $0 : nil } ?? selection.first ?? page
        selected = Set(min(from, page)...max(from, page))
        onSelect?()
    }

    public func selectAll() {
        selected = Set(cells.indices)
        onSelect?()
    }

    public func selectNone() {
        selected = []
        anchor = nil
        onSelect?()
    }

    /// A drag over `page` would land before it, or after it when `after`.
    public func mark(_ page: Int, after: Bool) {
        guard page >= 0, page < cells.count else { return }
        let cell = cells[page]
        if marked !== cell { unmark() }
        marked = cell
        cell.dropBefore = !after
        cell.dropAfter = after
    }

    public func unmark() {
        marked?.dropBefore = false
        marked?.dropAfter = false
        marked = nil
    }

    /// The index the marked gap stands before; the end when nothing is marked.
    public var dropIndex: Int {
        guard let marked else { return cells.count }
        return marked.dropAfter ? marked.index + 1 : marked.index
    }

    /// The drag ended over the marked gap: the pages it carries move there. Files dropped use `dropIndex` themselves.
    public func dropPages() {
        let before = dropIndex
        unmark()
        let pages = dragging
        dragging = []
        // The pages a drag carried may be gone when it lands, after an undo or an edit from elsewhere.
        if !pages.isEmpty, pages.allSatisfy({ $0 >= 0 && $0 < cells.count }) { moveTo(pages, before) }
    }
}
