import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/FillSign/PlacementTool.cs: takes one click, or one drag when the thing placed has a shape to
// draw, on a page. The drag shows a dashed outline of the box the picture will fill. Return on a keyboard arrives as a click.

@MainActor
final class PlacementTool: PagePointerTool {
    private static let clickSlop = 4.0
    private static let outline = "fillsign.outline"

    private let viewer: DocumentViewer
    private let aspect: Double
    private let placed: (Int, ViewPoint, ViewPoint?) -> Void
    private let stopped: () -> Void
    private var page = -1
    private var from = ViewPoint.zero
    private var pressedAt = ViewPoint.zero
    private var outlined: Int?

    /// - Parameters:
    ///   - aspect: Width over height of the picture placed; 0 for text, which has no box to drag.
    ///   - placed: The page, the place pressed and, for a drag, the place it ended.
    ///   - stopped: Escape ended the placement.
    init(_ viewer: DocumentViewer, aspect: Double, placed: @escaping (Int, ViewPoint, ViewPoint?) -> Void, stopped: @escaping () -> Void) {
        self.viewer = viewer
        self.aspect = aspect
        self.placed = placed
        self.stopped = stopped
    }

    var cursor: PointerCursor? { .crosshair }

    func press(_ pointer: PagePointer) {
        page = pointer.page
        from = pointer.point
        pressedAt = pointer.view
    }

    func move(_ pointer: PagePointer) {
        guard pointer.pressed, pointer.page == page, aspect > 0 else { return }
        let box = FillSignPlacement.fromDrag(from, pointer.point, aspect, viewer.pageSize(page))
        outlined = page
        viewer.overlay(page).set(OverlayItem(Self.outline, .rect(ViewRect(box.x, box.y, box.width, box.height)),
                                             style: OverlayStyle(stroke: .accent, lineWidth: 1.5, dash: [4, 3])))
    }

    func release(_ pointer: PagePointer) {
        guard page >= 0 else { return }
        let target = page
        let moved = hypot(pointer.view.x - pressedAt.x, pointer.view.y - pressedAt.y) > Self.clickSlop
        let dragged = aspect > 0 && pointer.page == target && moved
        clear()
        placed(target, from, dragged ? pointer.point : nil)
    }

    func cancel() {
        clear()
        stopped()
    }

    private func clear() {
        if let outlined { viewer.overlay(outlined).remove(Self.outline) }
        outlined = nil
        page = -1
    }
}
