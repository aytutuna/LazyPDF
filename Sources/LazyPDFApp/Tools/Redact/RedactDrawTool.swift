import Foundation

// Follows windows/LazyPDF.App/Tools/Redact/RedactDrawTool.cs: takes the pointer to drag a box over a page; the box is reported
// in page space when the button is let go or the finger lifted.

@MainActor
final class RedactDrawTool: PagePointerTool {
    private static let smallest = 4.0
    private static let keyBox = ViewSize(160, 24)
    static let colour = OverlayColor(red: 0xC4 / 255, green: 0x2B / 255, blue: 0x1C / 255)

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
}
