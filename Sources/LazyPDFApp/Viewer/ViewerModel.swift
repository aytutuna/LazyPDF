import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Viewer/PageViewer.xaml.cs and the state of PageSurface.cs. The model behind the page viewer
// of both platforms: the views give it the size they have, the pointer and the keys, and draw what it says (`drawing`,
// `highlights`). Going places, the pointer, text, tiles and layers are in the extensions.

@MainActor
@Observable
public final class ViewerModel: DocumentViewer {
    @ObservationIgnored let makeRenderer: () -> DocumentRenderer
    @ObservationIgnored let openAddress: (URL) -> Void

    @ObservationIgnored var state = PageSurfaceState()
    @ObservationIgnored var history = PageHistory()
    @ObservationIgnored var labels: [String] = []
    @ObservationIgnored var bytes: [UInt8] = []
    @ObservationIgnored var seenRevision = 0
    @ObservationIgnored var beforeReading: (columns: Int, cover: Bool, continuous: Bool, fit: FitMode, zoom: Double)?

    // Pictures
    @ObservationIgnored let cache = TileCache<TilePicture>(budget: 192 * 1024 * 1024)
    @ObservationIgnored let drawer = TileDrawer()
    @ObservationIgnored var failed = Set<TileKey>()
    @ObservationIgnored var scheduler: TileScheduler?
    @ObservationIgnored var generation = 0
    @ObservationIgnored var planQueued = false
    @ObservationIgnored var settling = false
    @ObservationIgnored var settleTask: Task<Void, Never>?

    // Layers
    @ObservationIgnored var layerChanges: [PdfReference: Bool] = [:]
    @ObservationIgnored var displaySession: PdfEditSession?
    @ObservationIgnored var displayRenderer: DocumentRenderer?
    @ObservationIgnored var layerTicket = 0

    // Text
    @ObservationIgnored let selected = ViewerSelection()
    @ObservationIgnored var textTask: Task<TextSource?, Never>?
    @ObservationIgnored var source: TextSource?
    @ObservationIgnored var links: [Int: [PdfLink]] = [:]
    @ObservationIgnored var geometries: [Int: PageGeometry] = [:]
    @ObservationIgnored var hitShapes: [Int: (others: [[ViewPoint]], current: [[ViewPoint]])] = [:]
    @ObservationIgnored var selectionShapes: [Int: [[ViewPoint]]] = [:]
    @ObservationIgnored var preloadTask: Task<Void, Never>?
    @ObservationIgnored var anchorWaiting: PagePoint?
    @ObservationIgnored var multi: (start: Caret, end: Caret, clicks: Int)?

    // Pointer
    @ObservationIgnored var drag = Drag.none
    @ObservationIgnored var dragPage = 0
    @ObservationIgnored var down = ViewPoint.zero
    @ObservationIgnored var last = ViewPoint.zero
    @ObservationIgnored var downLink: PdfLink?
    @ObservationIgnored var moved = false
    @ObservationIgnored var autoScroll: Task<Void, Never>?

    /// The view should scroll to `offset` and be as big as `extent`: set after anything but the view's own scrolling.
    @ObservationIgnored public var onScroll: (() -> Void)?

    /// Something drawn changed: a tile came, a highlight moved.
    @ObservationIgnored public var onRedraw: (() -> Void)?

    public internal(set) var tab: DocumentTab?

    /// Moves with every scroll, zoom, rotation or rearrangement.
    public internal(set) var viewRevision = 0

    /// Moves with a change of page, zoom or arrangement; what the bar shows follows it.
    public internal(set) var shownRevision = 0

    public internal(set) var layerRevision = 0
    public internal(set) var findVisible = false

    /// Moves each time Find is asked for, so the field takes the focus again.
    public internal(set) var findRequest = 0
    public internal(set) var findSeed: String?
    public var goToPageVisible = false

    /// The address a link wants opened, until the person says yes or no.
    public internal(set) var pendingAddress: PendingAddress?

    /// The mark a keyboard placement stands on; the view draws a cross there.
    public internal(set) var placement: KeyPlacement?

    /// What the pointer looks like over the pages; nil for the arrow.
    public internal(set) var cursor: PointerCursor?

    var pointerMode = PointerMode.select
    var tool: PagePointerTool?
    var reading = false

    public init(makeRenderer: @escaping () -> DocumentRenderer, openAddress: @escaping (URL) -> Void) {
        self.makeRenderer = makeRenderer
        self.openAddress = openAddress
        selected.onChanged = { [weak self] in self?.selectionChanged() }
        watchSearch()
    }

    @ObservationIgnored
    public private(set) lazy var search = ViewerSearch(source: { [unowned self] in self.textSource() }, startPage: { [unowned self] in self.state.currentPage })

    // MARK: Showing a document

    public func show(_ tab: DocumentTab?) {
        endPointerTool()
        self.tab = tab
        history.clear()
        resetText()
        resetLayers()
        hideFind()
        pendingAddress = nil
        search.clear()
        resetTiles()
        geometries.removeAll()
        if let tab {
            drawer.use(tab.canDraw ? tab.renderer : nil)
            bytes = tab.session.current
            seenRevision = tab.revision
            labels = PdfPageLabels.labels(tab.document)
            apply(state.show(sizes: pageSizes(tab), pageObjects: PageSurfaceState.pageObjects(tab.document), page: tab.pageIndex, zoom: tab.zoom, fit: tab.fit))
            storeZoom(tab)
            tab.pageIndex = state.currentPage
            watchRevision(tab)
        } else {
            drawer.use(nil)
            bytes = []
            labels = []
            state.clear()
            apply([.view, .page, .options])
        }
    }

    /// Draws the new state of the file after a commit, an undo or a redo. The model follows `tab.revision` by itself; this is
    /// for a caller that wants it now.
    public func reload() {
        guard let tab, tab.revision != seenRevision else { return }
        seenRevision = tab.revision
        resetText()
        labels = PdfPageLabels.labels(tab.document)
        geometries.removeAll()
        let before = bytes
        bytes = tab.session.current
        let changed = RevisionDiff.changed(before, bytes)
        let document = tab.document
        failed.removeAll()
        drawer.use(displayRenderer ?? (tab.canDraw ? tab.renderer : nil))
        apply(state.reload(sizes: pageSizes(tab), pageObjects: PageSurfaceState.pageObjects(document), changed: changed) { page in
            changed.map { RevisionDiff.touches(document, document.pages[page], $0) } ?? true
        })
        reapplyLayers()
        if !search.query.isEmpty { search.restart() }
    }

    private func pageSizes(_ tab: DocumentTab) -> [ViewSize] {
        PageSurfaceState.pageSizes(tab.document, tab.canDraw ? tab.renderer : nil)
    }

    private func storeZoom(_ tab: DocumentTab) {
        tab.fit = state.fit
        tab.zoom = state.fit == .none ? state.zoom : 0
    }

    private func watchRevision(_ watched: DocumentTab) {
        withObservationTracking {
            _ = watched.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.tab === watched else { return }
                self.reload()
                self.watchRevision(watched)
            }
        }
    }

    // MARK: Applying a change of the surface

    func apply(_ change: SurfaceChange) {
        if change.isEmpty { return }
        if change.contains(.view) {
            viewRevision += 1
            source?.retain(state.layout.pageCount == 0 ? 0 : state.layout.pagesIn(state.viewRect).count)
            preloadText()
        }
        if !change.isDisjoint(with: [.page, .options]) { shownRevision += 1 }
        if change.contains(.page) { tab?.pageIndex = state.currentPage }
        if change.contains(.options), let tab { storeZoom(tab) }
        if change.contains(.zoom) { noteZoomChange() }
        onScroll?()
        scheduleTiles()
        onRedraw?()
    }

    // MARK: What the views give it

    /// The size of the area the pages show in and the device pixels in one point of it; a change refits a fitted zoom.
    public func setScreen(viewport: ViewSize, pixelsPerDip: Double) {
        apply(state.setPixelsPerDip(pixelsPerDip))
        apply(state.setViewport(viewport))
    }

    /// The scroll position the view has been moved to.
    public func scrollTo(x: Double, y: Double) {
        apply(state.scrollTo(x: x, y: y))
    }

    public func scroll(by dx: Double, _ dy: Double) {
        apply(state.scrollBy(dx, dy))
    }

    /// The pinch of a hand: the zoom grows by `factor` about `point` of the view.
    public func magnify(by factor: Double, about point: ViewPoint) {
        guard factor > 0, factor.isFinite, tab != nil else { return }
        apply(state.setZoom(state.zoom * factor, around: point))
    }

    /// A double tap: the page fills the width, and a second one comes in closer.
    public func toggleZoom(about point: ViewPoint) {
        if state.fit == .width {
            apply(state.setZoom(state.zoom * 2, around: point))
        } else {
            fit = .width
        }
    }

    public var offset: ViewPoint { ViewPoint(state.offsetX, state.offsetY) }

    public var extent: ViewSize { state.extent }

    public var viewport: ViewSize { state.viewport }

    public var pixelsPerDip: Double { state.pixelsPerDip }

    // MARK: DocumentViewer, looking

    public var pageIndex: Int {
        get {
            _ = shownRevision
            return state.currentPage
        }
        set { goToPage(newValue) }
    }

    public var zoom: Double {
        get {
            _ = shownRevision
            return state.zoom
        }
        set { apply(state.setZoom(newValue)) }
    }

    public var pageCount: Int {
        _ = shownRevision
        return state.pageCount
    }

    public func pageLabel(_ page: Int) -> String {
        page >= 0 && page < labels.count && !labels[page].isEmpty ? labels[page] : String(page + 1)
    }

    public var fit: FitMode {
        get {
            _ = shownRevision
            return state.fit
        }
        set { apply(state.setFit(newValue)) }
    }

    public var columns: Int {
        get {
            _ = shownRevision
            return state.columns
        }
        set { apply(state.setArrangement(columns: newValue, cover: state.cover, continuous: state.continuous)) }
    }

    public var coverPage: Bool {
        get {
            _ = shownRevision
            return state.cover
        }
        set { apply(state.setArrangement(columns: state.columns, cover: newValue, continuous: state.continuous)) }
    }

    public var continuous: Bool {
        get {
            _ = shownRevision
            return state.continuous
        }
        set { apply(state.setArrangement(columns: state.columns, cover: state.cover, continuous: newValue)) }
    }

    public var rotation: Int {
        get {
            _ = shownRevision
            return state.rotation
        }
        set { apply(state.setRotation(newValue)) }
    }

    public var tint: PageTint {
        get {
            _ = shownRevision
            return state.tint
        }
        set {
            let change = state.setTint(newValue)
            if change.isEmpty { return }
            cache.clear()
            failed.removeAll()
            apply(change)
        }
    }

    public var readingMode: Bool {
        get { reading }
        set {
            if newValue == reading { return }
            reading = newValue
            if newValue {
                beforeReading = (state.columns, state.cover, state.continuous, state.fit, state.zoom)
                apply(state.setArrangement(columns: 1, cover: false, continuous: true))
                apply(state.setFit(.width))
                hideFind()
            } else if let before = beforeReading {
                apply(state.setArrangement(columns: before.columns, cover: before.cover, continuous: before.continuous))
                apply(before.fit == .none ? state.setZoom(before.zoom) : state.setFit(before.fit))
            }
        }
    }

    public var visiblePages: [Int] {
        _ = viewRevision
        return state.layout.pageCount == 0 ? [] : state.layout.pagesIn(state.viewRect)
    }

    public func pageSize(_ page: Int) -> ViewSize {
        state.pageSize(page)
    }

    public func geometry(_ page: Int) -> PageGeometry {
        if let known = geometries[page] { return known }
        let made = PageGeometry(tab!.document.pages[page])
        geometries[page] = made
        return made
    }

    public func pageToView(_ page: Int) -> ViewMatrix? {
        state.pageMatrix(page)
    }

    public func viewToPage(_ view: ViewPoint, nearest: Bool) -> PagePoint? {
        guard view.x >= 0, view.y >= 0, view.x < state.viewport.width, view.y < state.viewport.height,
              let hit = state.hit(view, nearest: nearest) else { return nil }
        return PagePoint(hit.page, hit.point)
    }

    // MARK: Pointer mode and tool

    public var mode: PointerMode {
        get { pointerMode }
        set {
            if newValue == pointerMode && tool == nil { return }
            pointerMode = newValue
            pointerTool = nil
        }
    }

    public var pointerTool: PagePointerTool? {
        get { tool }
        set {
            if newValue === tool { return }
            endPointerTool()
            tool = newValue
            cursor = newValue?.cursor
        }
    }

    func endPointerTool() {
        endPlacement()
        if drag == .tool { drag = .none }
        tool?.cancel()
    }

    // MARK: The bar

    /// What the viewer has to say when the file cannot be drawn.
    public var cannotDraw: Bool {
        guard let tab else { return false }
        return !tab.canDraw
    }
}

/// An address from a link in the file, shown to the person before anything opens it.
public struct PendingAddress: Equatable {
    public let address: String
    public let openable: Bool
}

enum Drag {
    case none, pan, select, tool
}
