import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Measure/MeasureTool.cs: takes the pointer on the pages. Each click adds a point, snapping
// to the corners of the words on the page, until the shape is done. A finger gives no hover, so the live segment and the snap
// mark are what a mouse adds; a click snaps whatever made it.

@MainActor
final class MeasureTool: PagePointerTool {
    private static let snapPixels = 10.0

    private let viewer: DocumentViewer
    private(set) var snaps: [Int: [ViewPoint]] = [:]
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

    var finished: ((MeasureItem) -> Void)?
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
        let at = resolve(pointer, sameShape: true)
        if canFinish && near(at, points[0], pointer.page) {
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
        hover = resolve(pointer, sameShape: pointer.page == page)
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
        finished?(item)
    }

    /// Starts reading the words of the pages in view, so that the first click on one can snap too.
    func preload(_ pages: [Int]) {
        for page in pages { loadSnaps(page) }
    }

    /// Drops the snap points, which belong to the file as it was.
    func forget() {
        snaps.removeAll()
    }

    /// View points per point of the page; 0 while the page is not laid out.
    func scale(_ page: Int) -> Double {
        viewer.pageToView(page).map(ViewScale.of) ?? 0
    }

    private func resolve(_ pointer: PagePointer, sameShape: Bool) -> ViewPoint {
        snapped = false
        let at = pointer.point
        if (pointer.modifiers.contains(.shift) || straight) && sameShape, let last = points.last { return MeasureShape.straighten(last, at) }
        guard snap, let corners = snaps[pointer.page] else { return at }
        let scale = scale(pointer.page)
        guard scale > 0, let found = MeasureShape.nearest(corners, at, Self.snapPixels / scale) else { return at }
        snapped = true
        return found
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
            self.loading.remove(page)
            guard let text else {
                self.snaps[page] = []
                return
            }
            let geometry = self.viewer.geometry(page)
            self.snaps[page] = text.words.flatMap { word -> [ViewPoint] in
                let b = word.bounds
                return [(b.left, b.bottom), (b.right, b.bottom), (b.left, b.top), (b.right, b.top)].map {
                    let shown = geometry.toDisplay($0.0, $0.1)
                    return ViewPoint(shown.x, shown.y)
                }
            }
        }
    }
}
