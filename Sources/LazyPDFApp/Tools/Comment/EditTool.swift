import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Comment/EditTool.cs: selects a mark under the pointer, with a frame and eight handles to move
// and resize it, or round handles on the ends of a line and the corners of a polygon. The tool only previews; the change to the
// file is asked of the model when the button is released. The frame and handles are overlay items under "comment.sel.".

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
    private var vertex = -1
    private var picked = -1
    private var pickedAt = ViewPoint.zero
    private var crossOpen = false
    private var wanted = -1
    private var points: [ViewPoint]?
    private var moveOnly = false
    private var moving = false
    private var pressedAt = ViewPoint.zero
    private var pressPoint = ViewPoint.zero
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
    var vertexMoved: ((PdfAnnotation, Int, ViewPoint) -> Void)?

    /// A corner is wanted after the one with this number, at the point.
    var vertexAdded: ((PdfAnnotation, Int, ViewPoint) -> Void)?

    /// Delete on a picked corner or end; the number is 0-based.
    var vertexRemoved: ((PdfAnnotation, Int) -> Void)?

    /// A corner or end was picked, by a click on it or by Enter; the number is 0-based.
    var vertexPicked: ((Int) -> Void)?

    /// The picked corner or end changed, or was let go.
    var pickChanged: (() -> Void)?

    /// The corner or end that was picked and the Add and Remove buttons or the arrow keys work on; -1 when none.
    var pickedVertex: Int { picked }

    init(viewer: DocumentViewer, marker: @escaping () -> Marker) {
        self.viewer = viewer
        self.marker = marker
    }

    var cursor: PointerCursor? { nil }

    func select(_ mark: PdfAnnotation?) {
        wanted = -1
        clearPick()
        current = mark
        redraw()
        selectionChanged?()
    }

    /// Finds the selected mark again after the file changed; it is let go if it is gone.
    func refresh() {
        guard let mark = current, let reference = mark.reference else {
            clearPick()
            return
        }
        let count = points?.count
        current = marker().find(mark.pageIndex, reference.number)
        redraw()
        // A look change that settles late must not cost the person their pick, but an undo or redo that moved the corner does.
        if current == nil || points?.count != count || movedSincePick() { clearPick() }
        if wanted >= 0, let points, wanted < points.count {
            pick(wanted)
            vertexPicked?(wanted)
        }
        wanted = -1
        if current == nil { selectionChanged?() }
    }

    /// Picks a corner once the file has changed and the tool has found its mark again, as for a corner that was just added.
    func pickAfterRefresh(_ index: Int) {
        wanted = index
    }

    private func movedSincePick() -> Bool {
        guard picked >= 0, let points, picked < points.count else { return false }
        return hypot(points[picked].x - pickedAt.x, points[picked].y - pickedAt.y) >= 0.5
    }

    private func pick(_ index: Int) {
        picked = index
        if let points, index < points.count { pickedAt = points[index] }
        crossOpen = false
        redraw()
        pickChanged?()
    }

    func redraw() {
        remove()
        guard let mark = current, marker().onPage(mark) else { return }
        frame = marker().box(of: mark)
        points = marker().pointsOf(mark)
        moveOnly = Marker.isFixed(mark)
        let count = points?.count ?? 0
        if picked >= count { clearPick() }
        // An undo can leave fewer points than the one being dragged.
        if vertex >= count {
            vertex = -1
            handle = -1
            moving = false
        }
        draw(mark.pageIndex, frame)
    }

    /// Lets go of the picked corner and, when asked, closes the cross the arrow keys were moving.
    func clearPick(closeCross: Bool = true) {
        guard picked >= 0 else { return }
        picked = -1
        pickChanged?()
        guard crossOpen else { return }
        crossOpen = false
        viewer.placementEnded = nil
        if closeCross { viewer.cancelPlacement() }
    }

    /// Takes the frame off the page and lets go of the selection.
    func clear() {
        clearPick()
        remove()
        current = nil
    }

    // A finger that lands anywhere else scrolls the page.
    func takes(_ pointer: PagePointer) -> Bool {
        if !pointer.touch { return true }
        if handleGrabbed(pointer) != nil { return true }
        return markAt(pointer.page, pointer.point, touch: true) != nil
    }

    func key(_ key: ViewerKey, modifiers: PointerModifiers) -> Bool {
        guard let mark = current else { return false }
        switch key {
        case .delete, .backspace:
            // A picked corner goes, not the mark.
            if picked >= 0 {
                let index = picked
                clearPick()
                redraw()
                vertexRemoved?(mark, index)
                return true
            }
            deleteRequested?()
            return true
        case .escape:
            if picked >= 0 {
                clearPick()
                redraw()
                return true
            }
            select(nil)
            return true
        default:
            return false
        }
    }

    func handleUnder(_ pointer: PagePointer) -> Bool { handleGrabbed(pointer) != nil }

    // One lookup for press, takes and handleUnder: a corner of a line or shape, else a handle of the frame.
    private func handleGrabbed(_ pointer: PagePointer) -> Int? {
        guard let selected = current, selected.pageIndex == pointer.page, !moveOnly else { return nil }
        if let points { return vertexAt(points, pointer.point, pointer.page, touch: pointer.touch) }
        return handleAt(frame, pointer.point, pointer.page)
    }

    func press(_ pointer: PagePointer) {
        handle = -1
        vertex = -1
        moving = false
        if !pointer.fromKeys && picked >= 0 {
            clearPick()
            redraw()
        }
        if pointer.fromKeys, let keyed = current, keyed.pageIndex == pointer.page, let points, !moveOnly, keyedPress(keyed, points, pointer) { return }
        if let grabbed = handleGrabbed(pointer) {
            if let points {
                vertex = grabbed
                pressedAt = points[grabbed]
                pressPoint = pointer.point
            } else {
                handle = grabbed
                begin(pointer.point)
            }
            return
        }
        guard let hit = markAt(pointer.page, pointer.point, touch: pointer.touch) else {
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
        guard let mark = current, pointer.page == mark.pageIndex, pointer.pressed, moving || handle >= 0 || vertex >= 0 else { return }
        if vertex >= 0 {
            guard var points, vertex < points.count else { return }
            let size = viewer.overlay(mark.pageIndex).size
            // The corner keeps its offset from the pointer, so a finger that lands near it does not make it jump.
            var to = ViewPoint(pressedAt.x + pointer.point.x - pressPoint.x, pressedAt.y + pointer.point.y - pressPoint.y)
            if !pointer.fromKeys && pointer.modifiers.contains(.shift), let fixed = neighbour(mark, points) { to = MeasureShape.straighten(fixed, to) }
            points[vertex] = ViewPoint(min(max(to.x, 0), size.width), min(max(to.y, 0), size.height))
            self.points = points
            remove()
            draw(mark.pageIndex, frame)
            return
        }
        let dx = pointer.point.x - from.x, dy = pointer.point.y - from.y
        frame = keep(moving ? ViewRect(start.x + dx, start.y + dy, start.width, start.height) : resizedFrame(dx, dy), mark.pageIndex)
        remove()
        draw(mark.pageIndex, frame)
    }

    func release(_ pointer: PagePointer) {
        guard let mark = current, moving || handle >= 0 || vertex >= 0 else { return }
        let wasMoving = moving
        let dragged = vertex
        moving = false
        handle = -1
        vertex = -1
        if dragged >= 0 {
            guard let points, dragged < points.count else {
                redraw()
                return
            }
            let to = points[dragged]
            if hypot(to.x - pressedAt.x, to.y - pressedAt.y) < Self.exact / scale(mark.pageIndex) {
                // A click on a corner picks it.
                pick(dragged)
                vertexPicked?(dragged)
            } else {
                vertexMoved?(mark, dragged, to)
            }
            return
        }
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
        clearPick()
        moving = false
        handle = -1
        vertex = -1
        redraw()
    }

    // The first Enter on a corner picks it and puts the cross there; the Enter that ends the arrow keys moves it.
    private func keyedPress(_ mark: PdfAnnotation, _ points: [ViewPoint], _ pointer: PagePointer) -> Bool {
        if picked >= 0 && crossOpen {
            let index = picked
            clearPick(closeCross: false)
            if index < points.count, hypot(pointer.point.x - points[index].x, pointer.point.y - points[index].y) >= 0.5 {
                vertexMoved?(mark, index, pointer.point)
            } else {
                redraw()
            }
            return true
        }
        if picked >= 0 { clearPick() }
        if let index = vertexAt(points, pointer.point, pointer.page, touch: false) {
            picked = index
            pickedAt = points[index]
            crossOpen = true
            pickChanged?()
            viewer.placementEnded = { [weak self] in self?.placementEnded() }
            remove()
            draw(mark.pageIndex, frame)
            viewer.beginPlacement(page: mark.pageIndex, point: points[index])
            vertexPicked?(index)
            return true
        }
        let side = marker().segmentAt(mark, pointer.point, tolerance: Self.exact)
        if side >= 0 {
            vertexAdded?(mark, side, pointer.point)
            return true
        }
        return false
    }

    // Escape closed the cross, so there is nothing left to move.
    private func placementEnded() {
        clearPick(closeCross: false)
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
    private func markAt(_ page: Int, _ point: ViewPoint, touch: Bool) -> PdfAnnotation? {
        if !touch { return marker().at(page, point, Self.exact) }
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

    // Shift straightens the dragged point against the one before it; the first end of an open shape takes the next one.
    private func neighbour(_ mark: PdfAnnotation, _ points: [ViewPoint]) -> ViewPoint? {
        guard points.count > 1 else { return nil }
        if vertex > 0 { return points[vertex - 1] }
        return mark.type == .polygon ? points[points.count - 1] : points[1]
    }

    // The nearer corner wins within reach, and a press between two close corners belongs to neither, so a short line can still
    // be moved. A finger reaches as far as its slop allows.
    private func vertexAt(_ points: [ViewPoint], _ at: ViewPoint, _ page: Int, touch: Bool) -> Int? {
        func distance(_ i: Int) -> Double { hypot(points[i].x - at.x, points[i].y - at.y) }
        guard let nearest = points.indices.min(by: { distance($0) < distance($1) }) else { return nil }
        let gap = points.indices.filter { $0 != nearest }.map { hypot(points[$0].x - points[nearest].x, points[$0].y - points[nearest].y) }.min()
        let own = touch ? reach(page) : Self.grip / 2 / scale(page) + 2
        return distance(nearest) <= min(own, (gap ?? .infinity) / 2) ? nearest : nil
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
        if moveOnly { return }
        for (i, spot) in (points ?? Self.spots(frame)).enumerated() {
            overlay.set(OverlayItem(Self.selectionPrefix + "grip.\(i)", .marker(center: spot, size: Self.grip, round: points != nil),
                                    style: OverlayStyle(stroke: .accent, fill: i == picked && points != nil ? .accent : .white, lineWidth: 1.5)))
        }
    }

    private func remove() {
        if drawnOn >= 0 && drawnOn < viewer.pageCount { viewer.overlay(drawnOn).remove(prefix: Self.selectionPrefix) }
        drawnOn = -1
    }
}
