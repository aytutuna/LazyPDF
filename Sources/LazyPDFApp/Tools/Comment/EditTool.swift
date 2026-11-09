import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Comment/EditTool.cs: selects a mark under the pointer, with a frame and eight handles to move
// and resize it. The tool only previews; the change to the file is asked of the model when the button is released. The frame
// and handles are overlay items under "comment.sel.".

@MainActor
final class EditTool: PagePointerTool {
    static let selectionPrefix = "comment.sel."
    private static let slop = 24.0
    private static let exact = 4.0
    private static let grip = 9.0
    private static let minSize = 8.0

    private let viewer: DocumentViewer
    private let marker: () -> Marker
    private var handle = -1
    private var moving = false
    private var from = ViewPoint.zero
    private var start = ViewRect(0, 0, 0, 0)
    private var frame = ViewRect(0, 0, 0, 0)
    private var drawnOn = -1

    /// The mark that is selected; nil when none is.
    private(set) var current: PdfAnnotation?

    var selectionChanged: (() -> Void)?
    var moved: ((PdfAnnotation, Double, Double) -> Void)?
    var resized: ((PdfAnnotation, ViewRect) -> Void)?
    var editRequested: ((PdfAnnotation) -> Void)?
    var deleteRequested: (() -> Void)?

    init(viewer: DocumentViewer, marker: @escaping () -> Marker) {
        self.viewer = viewer
        self.marker = marker
    }

    var cursor: PointerCursor? { nil }

    func select(_ mark: PdfAnnotation?) {
        current = mark
        redraw()
        selectionChanged?()
    }

    /// Finds the selected mark again after the file changed; it is let go if it is gone.
    func refresh() {
        guard let mark = current, let reference = mark.reference else { return }
        current = marker().find(mark.pageIndex, reference.number)
        redraw()
        if current == nil { selectionChanged?() }
    }

    func redraw() {
        remove()
        guard let mark = current, marker().onPage(mark) else { return }
        frame = marker().box(of: mark)
        draw(mark.pageIndex, frame)
    }

    /// Takes the frame off the page and lets go of the selection.
    func clear() {
        remove()
        current = nil
    }

    // A finger that lands anywhere else scrolls the page.
    func takes(_ pointer: PagePointer) -> Bool {
        if let selected = current, selected.pageIndex == pointer.page, handleAt(frame, pointer.point, pointer.page) != nil { return true }
        return hit(pointer.page, pointer.point) != nil
    }

    func key(_ key: ViewerKey, modifiers: PointerModifiers) -> Bool {
        guard current != nil else { return false }
        switch key {
        case .delete, .backspace:
            deleteRequested?()
            return true
        case .escape:
            select(nil)
            return true
        default:
            return false
        }
    }

    func press(_ pointer: PagePointer) {
        handle = -1
        moving = false
        if let selected = current, selected.pageIndex == pointer.page, let grabbed = handleAt(frame, pointer.point, pointer.page) {
            handle = grabbed
            begin(pointer.point)
            return
        }
        guard let hit = hit(pointer.page, pointer.point) else {
            if current != nil { select(nil) }
            return
        }
        if current?.reference?.number != hit.reference?.number || current?.pageIndex != hit.pageIndex { select(hit) }
        frame = marker().box(of: hit)
        if pointer.clicks >= 2 {
            editRequested?(hit)
            return
        }
        moving = true
        begin(pointer.point)
    }

    func move(_ pointer: PagePointer) {
        guard let mark = current, pointer.page == mark.pageIndex, pointer.pressed, moving || handle >= 0 else { return }
        let dx = pointer.point.x - from.x, dy = pointer.point.y - from.y
        frame = keep(moving ? ViewRect(start.x + dx, start.y + dy, start.width, start.height) : resizedFrame(dx, dy), mark.pageIndex)
        remove()
        draw(mark.pageIndex, frame)
    }

    func release(_ pointer: PagePointer) {
        guard let mark = current, moving || handle >= 0 else { return }
        let wasMoving = moving
        moving = false
        handle = -1
        if abs(frame.x - start.x) < 0.5 && abs(frame.y - start.y) < 0.5 && abs(frame.width - start.width) < 0.5
            && abs(frame.height - start.height) < 0.5 {
            redraw()
            return
        }
        if wasMoving {
            moved?(mark, frame.x - start.x, frame.y - start.y)
        } else {
            resized?(mark, frame)
        }
    }

    func cancel() {
        moving = false
        handle = -1
        redraw()
    }

    private func begin(_ at: ViewPoint) {
        from = at
        start = frame
    }

    private func scale(_ page: Int) -> Double {
        guard let matrix = viewer.pageToView(page) else { return 1 }
        let scale = ViewScale.of(matrix)
        return scale > 0 ? scale : 1
    }

    // What lies under the point itself wins, as on a mouse; a finger's slop only finds the nearest mark when none does.
    private func hit(_ page: Int, _ point: ViewPoint) -> PdfAnnotation? {
        let wide = reach(page)
        var by = min(Self.exact, wide)
        while by < wide {
            if let mark = marker().at(page, point, by) { return mark }
            by = min(by * 2, wide)
        }
        return marker().at(page, point, wide)
    }

    // The reach of a finger, in page space.
    private func reach(_ page: Int) -> Double {
        Self.slop / scale(page)
    }

    // Handles run clockwise from the top left corner: corners at even places, sides at odd.
    private func resizedFrame(_ dx: Double, _ dy: Double) -> ViewRect {
        var left = start.left, top = start.top, right = start.right, bottom = start.bottom
        if [0, 6, 7].contains(handle) { left = min(left + dx, right - Self.minSize) }
        if [2, 3, 4].contains(handle) { right = max(right + dx, left + Self.minSize) }
        if [0, 1, 2].contains(handle) { top = min(top + dy, bottom - Self.minSize) }
        if [4, 5, 6].contains(handle) { bottom = max(bottom + dy, top + Self.minSize) }
        return ViewRect(from: ViewPoint(left, top), to: ViewPoint(right, bottom))
    }

    // A mark dragged off the page could not be picked again, so the frame stops at the edge.
    private func keep(_ frame: ViewRect, _ page: Int) -> ViewRect {
        let size = viewer.overlay(page).size
        let bounds = ViewRect(0, 0, size.width, size.height)
        if !moving {
            let inside = ViewRect.intersect(frame, bounds)
            return inside.isEmpty ? frame : inside
        }
        return ViewRect(min(max(frame.x, 0), max(0, bounds.width - frame.width)),
                        min(max(frame.y, 0), max(0, bounds.height - frame.height)), frame.width, frame.height)
    }

    // The nearest handle within reach. A small mark keeps most of its area for moving.
    private func handleAt(_ frame: ViewRect, _ at: ViewPoint, _ page: Int) -> Int? {
        let own = Self.grip / 2 / scale(page) + 2
        let reach = min(self.reach(page), max(min(frame.width, frame.height) / 3, own))
        var best: Int?
        var nearest = reach
        for (i, spot) in Self.spots(frame).enumerated() {
            let d = ((spot.x - at.x) * (spot.x - at.x) + (spot.y - at.y) * (spot.y - at.y)).squareRoot()
            if d <= nearest {
                nearest = d
                best = i
            }
        }
        return best
    }

    private static func spots(_ r: ViewRect) -> [ViewPoint] {
        let mx = r.x + r.width / 2, my = r.y + r.height / 2
        return [ViewPoint(r.left, r.top), ViewPoint(mx, r.top), ViewPoint(r.right, r.top), ViewPoint(r.right, my),
                ViewPoint(r.right, r.bottom), ViewPoint(mx, r.bottom), ViewPoint(r.left, r.bottom), ViewPoint(r.left, my)]
    }

    private func draw(_ page: Int, _ frame: ViewRect) {
        guard page >= 0, page < viewer.pageCount else { return }
        let overlay = viewer.overlay(page)
        drawnOn = page
        overlay.set(OverlayItem(Self.selectionPrefix + "frame", .rect(frame), style: OverlayStyle(stroke: .accent, lineWidth: 1.5, dash: [4, 3])))
        for (i, spot) in Self.spots(frame).enumerated() {
            overlay.set(OverlayItem(Self.selectionPrefix + "grip.\(i)", .marker(center: spot, size: Self.grip, round: false),
                                    style: OverlayStyle(stroke: .accent, fill: .white, lineWidth: 1.5)))
        }
    }

    private func remove() {
        if drawnOn >= 0 && drawnOn < viewer.pageCount { viewer.overlay(drawnOn).remove(prefix: Self.selectionPrefix) }
        drawnOn = -1
    }
}
