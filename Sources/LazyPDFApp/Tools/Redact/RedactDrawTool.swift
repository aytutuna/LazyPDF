import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Redact/RedactDrawTool.cs and RedactBoxEditor.cs: takes the pointer to drag a box over a
// page, and to move and resize the box that is selected in the list; the box is reported in page space when the button is let
// go or the finger lifted. The frame and handles of the selected box are overlay items under "redact.edit.".

@MainActor
final class RedactDrawTool: PagePointerTool {
    nonisolated static let smallest = 4.0
    static let editPrefix = "redact.edit."
    private static let keyBox = ViewSize(160, 24)
    private static let grip = 9.0
    static let colour = OverlayColor(red: 0xC4 / 255, green: 0x2B / 255, blue: 0x1C / 255)

    /// The body of a box and its eight handles, clockwise from the top left.
    enum Handle: CaseIterable {
        case body, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    enum Arrow {
        case left, right, up, down
    }

    private let viewer: DocumentViewer
    private let boxDrawn: (Int, ViewPoint, ViewPoint) -> Void
    private let boxEdited: (MarkItem, ViewRect, PageGeometry, Bool) -> Bool
    private var page = -1
    private var from = ViewPoint(0, 0)

    // The selected box, where it is shown and the geometry that went with that. A drag works in page space on the rectangle
    // it began with and is turned into a mark once, with that geometry: the viewer may show another file by then.
    private var item: MarkItem?
    private var geometry: PageGeometry?
    private var frame = ViewRect(0, 0, 0, 0)
    private var handle: Handle?
    private var grab = ViewPoint.zero
    private var dragged = ViewRect(0, 0, 0, 0)
    private var shownOn = -1

    /// Whether a press away from the selected box draws a new one.
    var drawing = false

    init(_ viewer: DocumentViewer, boxDrawn: @escaping (Int, ViewPoint, ViewPoint) -> Void,
         boxEdited: @escaping (MarkItem, ViewRect, PageGeometry, Bool) -> Bool) {
        self.viewer = viewer
        self.boxDrawn = boxDrawn
        self.boxEdited = boxEdited
    }

    var cursor: PointerCursor? { drawing ? .crosshair : nil }

    /// Frames `item` when it is a box on a page of the viewer; nil takes the frame away. A drag that was under way is dropped.
    func show(_ item: MarkItem?, _ geometry: PageGeometry?) {
        handle = nil
        remove()
        guard let item, let geometry, item.isBox, item.page < viewer.pageCount else {
            self.item = nil
            self.geometry = nil
            return
        }
        self.item = item
        self.geometry = geometry
        frame = MarkShapes.place(geometry, item.mark)
        draw(frame)
    }

    // What lies under a finger or the pointer: a handle of the selected box, else its body.
    private func target(_ pointer: PagePointer) -> Handle? {
        guard let item, handle == nil, pointer.page == item.page else { return nil }
        let scale = viewer.pageToView(item.page).map(ViewScale.of) ?? 1
        let unit = scale > 0 ? scale : 1
        let own = Self.grip / 2 / unit + 2
        let reach = min((pointer.touch ? 22 : 12) / unit, max(min(frame.width, frame.height) / 3, own))
        var best: Handle?
        var nearest = reach
        for (spot, which) in zip(Self.spots(frame), Handle.allCases.dropFirst()) {
            let d = ((spot.x - pointer.point.x) * (spot.x - pointer.point.x) + (spot.y - pointer.point.y) * (spot.y - pointer.point.y)).squareRoot()
            if d <= nearest {
                nearest = d
                best = which
            }
        }
        return best ?? (frame.contains(pointer.point) ? .body : nil)
    }

    // A finger that lands anywhere else scrolls the page, and a click goes to the viewer, unless a new box is being drawn.
    func takes(_ pointer: PagePointer) -> Bool {
        drawing || target(pointer) != nil
    }

    func press(_ pointer: PagePointer) {
        cancel()
        if let grabbed = target(pointer) {
            handle = grabbed
            grab = pointer.point
            dragged = frame
            return
        }
        guard drawing else { return }
        page = pointer.page
        from = clamp(pointer.page, pointer.point)
        place(from)
    }

    func move(_ pointer: PagePointer) {
        if let handle, let item {
            guard pointer.pressed, pointer.page == item.page else { return }
            let delta = ViewPoint(pointer.point.x - grab.x, pointer.point.y - grab.y)
            dragged = Self.drag(frame, handle, delta, viewer.pageSize(item.page))
            draw(dragged)
            return
        }
        guard page >= 0, pointer.pressed, pointer.page == page else { return }
        place(clamp(page, pointer.point))
    }

    func release(_ pointer: PagePointer) {
        if handle != nil {
            move(PagePointer(page: pointer.page, point: pointer.point, view: pointer.view, pressed: true, clicks: 0))
            finish()
            return
        }
        guard page >= 0 else { return }
        var to = clamp(page, pointer.point)
        let (done, start) = (page, from)
        cancel()
        // The keyboard sends a click, which gets a box of the usual size.
        if pointer.fromKeys && abs(to.x - start.x) < Self.smallest && abs(to.y - start.y) < Self.smallest {
            to = clamp(done, ViewPoint(start.x + Self.keyBox.width, start.y + Self.keyBox.height))
        }
        if abs(to.x - start.x) >= Self.smallest && abs(to.y - start.y) >= Self.smallest { boxDrawn(done, start, to) }
    }

    /// Ends a drag of the selected box where it stands, for a caller that must have the list as the page shows it.
    func finish() {
        guard let grabbed = handle, let old = item, let geometry else { return }
        handle = nil
        if dragged == frame {
            draw(frame)
            return
        }
        // A refused edit, while the copy is being made, leaves the list as it was, so the frame goes back to it.
        if !boxEdited(old, dragged, geometry, grabbed != .body) { draw(frame) }
    }

    func cancel() {
        if page >= 0 { viewer.overlay(page).remove("redact.preview") }
        page = -1
        if handle != nil {
            handle = nil
            draw(frame)
        }
    }

    private func place(_ to: ViewPoint) {
        let box = ViewRect(min(from.x, to.x), min(from.y, to.y), abs(to.x - from.x), abs(to.y - from.y))
        viewer.overlay(page).set(OverlayItem("redact.preview", .rect(box), style: OverlayStyle(
            stroke: Self.colour, fill: Self.colour.opacity(0.19), lineWidth: 1, dash: [4, 3])))
    }

    private func clamp(_ page: Int, _ point: ViewPoint) -> ViewPoint {
        let size = viewer.pageSize(page)
        return ViewPoint(min(max(point.x, 0), size.width), min(max(point.y, 0), size.height))
    }

    // Handles run clockwise from the top left corner: corners at even places, sides at odd.
    private static func spots(_ r: ViewRect) -> [ViewPoint] {
        let mx = r.x + r.width / 2, my = r.y + r.height / 2
        return [ViewPoint(r.left, r.top), ViewPoint(mx, r.top), ViewPoint(r.right, r.top), ViewPoint(r.right, my),
                ViewPoint(r.right, r.bottom), ViewPoint(mx, r.bottom), ViewPoint(r.left, r.bottom), ViewPoint(r.left, my)]
    }

    private func draw(_ rect: ViewRect) {
        guard let item, item.page < viewer.pageCount else { return }
        let overlay = viewer.overlay(item.page)
        shownOn = item.page
        overlay.set(OverlayItem(Self.editPrefix + "frame", .rect(rect), style: OverlayStyle(stroke: .accent, lineWidth: 1.5, dash: [4, 3])))
        for (i, spot) in Self.spots(rect).enumerated() {
            overlay.set(OverlayItem(Self.editPrefix + "grip.\(i)", .marker(center: spot, size: Self.grip, round: false),
                                    style: OverlayStyle(stroke: .accent, fill: .white, lineWidth: 1.5)))
        }
    }

    private func remove() {
        if shownOn >= 0 && shownOn < viewer.pageCount { viewer.overlay(shownOn).remove(prefix: Self.editPrefix) }
        shownOn = -1
    }

    /// The box after a drag of `delta` (page space) on `handle`, kept on the page and at least `smallest` across.
    nonisolated static func drag(_ rect: ViewRect, _ handle: Handle, _ delta: ViewPoint, _ page: ViewSize, smallest: Double = smallest) -> ViewRect {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), high) }
        if handle == .body {
            return ViewRect(clamp(rect.x + delta.x, 0, max(0, page.width - rect.width)),
                            clamp(rect.y + delta.y, 0, max(0, page.height - rect.height)), rect.width, rect.height)
        }
        var (left, top, right, bottom) = (rect.left, rect.top, rect.right, rect.bottom)
        if [.topLeft, .left, .bottomLeft].contains(handle) { left = clamp(left + delta.x, 0, max(0, right - smallest)) }
        if [.topRight, .right, .bottomRight].contains(handle) { right = clamp(right + delta.x, left + smallest, max(left + smallest, page.width)) }
        if [.topLeft, .top, .topRight].contains(handle) { top = clamp(top + delta.y, 0, max(0, bottom - smallest)) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { bottom = clamp(bottom + delta.y, top + smallest, max(top + smallest, page.height)) }
        return ViewRect(left, top, right - left, bottom - top)
    }

    /// The box after an arrow key: it moves, or with `resize` the right and bottom edges move instead. A step is 1 point, 10 when `large`.
    nonisolated static func nudge(_ rect: ViewRect, _ arrow: Arrow, resize: Bool, large: Bool, _ page: ViewSize) -> ViewRect {
        let step = large ? 10.0 : 1.0
        let delta: ViewPoint
        switch arrow {
        case .left: delta = ViewPoint(-step, 0)
        case .right: delta = ViewPoint(step, 0)
        case .up: delta = ViewPoint(0, -step)
        case .down: delta = ViewPoint(0, step)
        }
        if !resize { return drag(rect, .body, delta, page) }
        return drag(rect, arrow == .left || arrow == .right ? .right : .bottom, delta, page)
    }
}
