import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Measure/MeasureTool.cs: takes the pointer on the pages. Each click adds a point, snapping
// to the corners of the words and the lines, pictures and corners the page draws (Option turns that off), until the shape is done. A finger gives no hover, so the live segment and the snap
// mark are what a mouse adds; a click snaps whatever made it.

@MainActor
final class MeasureTool: PagePointerTool {
    private static let snapPixels = 10.0

    private let viewer: DocumentViewer
    private(set) var snaps: [Int: [ViewPoint]] = [:]
    private(set) var lines: [Int: [(ViewPoint, ViewPoint)]] = [:]
    private var loading = Set<Int>()
    private var added = false
    private var waiting: PagePointer?

    var kind = MeasureKind.distance
    var snap = true

    /// Shift for straight lines, held for a finger by the panel.
    var straight = false

    private(set) var points: [ViewPoint] = []

    /// The page of the shape being drawn; -1 when none is.
    private(set) var page = -1

    /// Where the next click would land, on the page of the last move of a mouse that is not pressed.
    private(set) var hover: ViewPoint?
    private(set) var hoverPage = -1
    private(set) var snapped = false

    /// A distance of two points reports its length through `calibrated` instead of becoming an item.
    var calibrate = false

    var finished: ((MeasureItem) -> Void)?

    /// The page and the length in points of the two ends clicked in calibrate mode.
    var calibrated: ((Int, Double) -> Void)?
    var changed: (() -> Void)?

    init(viewer: DocumentViewer) {
        self.viewer = viewer
    }

    var cursor: PointerCursor? { .crosshair }

    var canFinish: Bool { kind != .distance && points.count >= 3 }

    func key(_ key: ViewerKey, modifiers: PointerModifiers) -> Bool {
        guard !points.isEmpty else { return false }
        switch key {
        case .escape: reset()
        case .backspace: undo()
        default: return false
        }
        return true
    }

    func handleUnder(_ pointer: PagePointer) -> Bool { onFirstDot(pointer) }

    // The resolved point, as a click is closed on; resolving here changes nothing, so asking leaves `snapped` alone.
    private func onFirstDot(_ pointer: PagePointer) -> Bool {
        canFinish && pointer.page == page && near(resolved(pointer, sameShape: true).point, points[0], pointer.page)
    }

    func press(_ pointer: PagePointer) {
        // A second finger cancels the press, so a finger's point is added on release.
        if pointer.touch {
            waiting = pointer
        } else {
            commit(pointer)
        }
    }

    private func commit(_ pointer: PagePointer) {
        if !points.isEmpty && pointer.page != page { return }
        page = pointer.page
        if pointer.clicks >= 2 {
            // The first click of the double already put its point here.
            if kind != .distance { finish() }
            return
        }
        loadSnaps(pointer.page)
        let (at, isSnapped) = resolved(pointer, sameShape: true)
        snapped = isSnapped
        if onFirstDot(pointer) {
            finish()
            return
        }
        points.append(at)
        added = true
        if kind == .distance && points.count == 2 {
            finish()
        } else {
            changed?()
        }
    }

    func move(_ pointer: PagePointer) {
        if pointer.pressed { return }
        let (point, isSnapped) = resolved(pointer, sameShape: pointer.page == page)
        (hover, snapped) = (point, isSnapped)
        hoverPage = pointer.page
        loadSnaps(pointer.page)
        changed?()
    }

    func release(_ pointer: PagePointer) {
        added = false
        if let tapped = waiting {
            waiting = nil
            commit(tapped)
            added = false
        }
    }

    /// The press in flight was taken away (a second finger, another window): the corner it added goes, the others stay.
    func cancel() {
        waiting = nil
        if added {
            added = false
            undo()
        }
    }

    /// Drops the shape under way.
    func reset() {
        points.removeAll()
        page = -1
        hover = nil
        snapped = false
        added = false
        waiting = nil
        changed?()
    }

    /// Takes back the last corner.
    func undo() {
        if points.isEmpty { return }
        points.removeLast()
        if points.isEmpty { page = -1 }
        changed?()
    }

    func finish() {
        if !canFinish && !(kind == .distance && points.count == 2) { return }
        let item = MeasureItem(kind, page, points)
        points.removeAll()
        page = -1
        added = false
        changed?()
        if !calibrate {
            finished?(item)
        } else {
            // Two clicks on one spot say nothing about a length; the user draws the line again.
            let length = MeasureShape.distance(item.points[0], item.points[1])
            if length > 0.01 { calibrated?(item.page, length) }
        }
    }

    /// Starts reading the words of the pages in view, so that the first click on one can snap too.
    func preload(_ pages: [Int]) {
        for page in pages { loadSnaps(page) }
    }

    /// Drops the snap points, which belong to the file as it was.
    func forget() {
        snaps.removeAll()
        lines.removeAll()
    }

    /// View points per point of the page; 0 while the page is not laid out.
    func scale(_ page: Int) -> Double {
        viewer.pageToView(page).map(ViewScale.of) ?? 0
    }

    private func resolved(_ pointer: PagePointer, sameShape: Bool) -> (point: ViewPoint, snapped: Bool) {
        let at = pointer.point
        if (pointer.modifiers.contains(.shift) || straight) && sameShape, let last = points.last { return (MeasureShape.straighten(last, at), false) }
        guard snap, !pointer.modifiers.contains(.option), let corners = snaps[pointer.page] else { return (at, false) }
        let scale = scale(pointer.page)
        if scale <= 0 { return (at, false) }
        let radius = Self.snapPixels / scale
        let found = MeasureShape.nearest(corners, at, radius) ?? MeasureShape.nearestOnLines(lines[pointer.page] ?? [], at, radius)
        guard let found else { return (at, false) }
        return (found, true)
    }

    private func near(_ a: ViewPoint, _ b: ViewPoint, _ page: Int) -> Bool {
        let scale = scale(page)
        return scale > 0 && MeasureShape.distance(a, b) * scale <= Self.snapPixels
    }

    private func loadSnaps(_ page: Int) {
        guard snap, snaps[page] == nil, loading.insert(page).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            let text = await self.viewer.text(page)
            let drawn = await self.viewer.drawing(page)
            self.loading.remove(page)
            let geometry = self.viewer.geometry(page)
            func shown(_ x: Double, _ y: Double) -> ViewPoint {
                let p = geometry.toDisplay(x, y)
                return ViewPoint(p.x, p.y)
            }
            let edges = drawn.map { (shown($0.x1, $0.y1), shown($0.x2, $0.y2)) }
            let words = (text?.words ?? []).flatMap { word -> [ViewPoint] in
                let b = word.bounds
                return [(b.left, b.bottom), (b.right, b.bottom), (b.left, b.top), (b.right, b.top)].map { shown($0.0, $0.1) }
            }
            self.lines[page] = edges.filter { $0.0 != $0.1 }
            self.snaps[page] = words + edges.map { $0.0 } + edges.map { $0.1 }
        }
    }
}
