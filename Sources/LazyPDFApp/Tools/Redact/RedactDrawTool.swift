import Foundation

// Follows windows/LazyPDF.App/Tools/Redact/RedactDrawTool.cs: takes the pointer to drag a box over a page; the box is reported
// in page space when the button is let go or the finger lifted.

@MainActor
final class RedactDrawTool: PagePointerTool {
    nonisolated static let smallest = 4.0
    private static let keyBox = ViewSize(160, 24)
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
    private var page = -1
    private var from = ViewPoint(0, 0)

    init(_ viewer: DocumentViewer, boxDrawn: @escaping (Int, ViewPoint, ViewPoint) -> Void) {
        self.viewer = viewer
        self.boxDrawn = boxDrawn
    }

    var cursor: PointerCursor? { .crosshair }

    func press(_ pointer: PagePointer) {
        cancel()
        page = pointer.page
        from = clamp(pointer.page, pointer.point)
        place(from)
    }

    func move(_ pointer: PagePointer) {
        guard page >= 0, pointer.pressed, pointer.page == page else { return }
        place(clamp(page, pointer.point))
    }

    func release(_ pointer: PagePointer) {
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

    func cancel() {
        if page >= 0 { viewer.overlay(page).remove("redact.preview") }
        page = -1
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
