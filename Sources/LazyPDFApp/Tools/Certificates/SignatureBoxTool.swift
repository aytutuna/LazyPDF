import Foundation

// Follows windows/LazyPDF.App/Tools/Certificates/SignatureBoxTool.cs: takes a drag on a page as the box where a visible signature
// goes.

@MainActor
final class SignatureBoxTool: PagePointerTool {
    private static let minSide = 20.0
    private static let keyBox = ViewSize(180, 60)
    static let outlineId = "certificates.box"
    private static let previewId = "certificates.preview"

    private let viewer: DocumentViewer
    private let drawn: (Int, ViewRect) -> Void
    private let stopped: () -> Void
    private var page = -1
    private var from = ViewPoint(0, 0)

    init(_ viewer: DocumentViewer, drawn: @escaping (Int, ViewRect) -> Void, stopped: @escaping () -> Void) {
        self.viewer = viewer
        self.drawn = drawn
        self.stopped = stopped
    }

    var cursor: PointerCursor? { .crosshair }

    func press(_ pointer: PagePointer) {
        page = pointer.page
        from = pointer.point
    }

    func move(_ pointer: PagePointer) {
        guard page >= 0, pointer.pressed, pointer.page == page else { return }
        viewer.overlay(page).set(Self.outline(Self.previewId, box(pointer.point)))
    }

    func release(_ pointer: PagePointer) {
        guard page >= 0 else { return }
        let done = page
        var area = box(pointer.point)
        // The keyboard sends a click, which gets a box of the usual size.
        if pointer.fromKeys && area.width < 3 && area.height < 3 { area = fit(from) }
        clear()
        if area.width >= Self.minSide && area.height >= Self.minSide { drawn(done, area) }
    }

    // A press that is taken away (a second finger starting a scroll) only drops its preview; the tool waits for the next drag.
    func cancel() {
        let pressed = page >= 0
        clear()
        if !pressed { stopped() }
    }

    /// A dashed outline for a box on the page, in the accent colour; the caller removes it.
    static func outline(_ id: String, _ area: ViewRect) -> OverlayItem {
        OverlayItem(id, .rect(area), style: OverlayStyle(stroke: .accent, lineWidth: 1.5, dash: [4, 3]))
    }

    // Clamped to the page, so a drag past its edge still gives a box that is on it.
    private func box(_ to: ViewPoint) -> ViewRect {
        let size = viewer.pageSize(page)
        let a = ViewPoint(min(max(from.x, 0), size.width), min(max(from.y, 0), size.height))
        let b = ViewPoint(min(max(to.x, 0), size.width), min(max(to.y, 0), size.height))
        return ViewRect(min(a.x, b.x), min(a.y, b.y), abs(a.x - b.x), abs(a.y - b.y))
    }

    private func fit(_ at: ViewPoint) -> ViewRect {
        let size = viewer.pageSize(page)
        return ViewRect(max(0, min(at.x, size.width - Self.keyBox.width)), max(0, min(at.y, size.height - Self.keyBox.height)),
                        min(Self.keyBox.width, size.width), min(Self.keyBox.height, size.height))
    }

    private func clear() {
        if page >= 0 { viewer.overlay(page).remove(Self.previewId) }
        page = -1
    }
}
