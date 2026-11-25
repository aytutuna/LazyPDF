import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Pages/CropTool.cs: draws a box on a page with the pointer and keeps it, in page space, until
// the next drag or `clear`.

public struct CropBox: Equatable {
    public let page: Int
    public let area: DisplayRect
}

@MainActor
public final class CropTool: PagePointerTool {
    static let id = "pages.crop"
    static let keyBox = ViewSize(240, 160)

    private let viewer: DocumentViewer
    private var page = -1
    private var from = ViewPoint.zero
    private var dragging = false

    /// The page the box is on and the box; nil until one is drawn.
    public private(set) var box: CropBox?

    /// Called when `box` is set or cleared.
    public var onChange: (() -> Void)?

    public init(_ viewer: DocumentViewer) {
        self.viewer = viewer
    }

    public var cursor: PointerCursor? { .crosshair }

    public func press(_ pointer: PagePointer) {
        clear()
        page = pointer.page
        from = inside(pointer)
        dragging = true
        draw(from)
    }

    public func move(_ pointer: PagePointer) {
        if dragging && pointer.page == page { draw(inside(pointer)) }
    }

    public func release(_ pointer: PagePointer) {
        guard dragging else { return }
        dragging = false
        var to = inside(pointer)
        draw(to)
        var width = abs(to.x - from.x), height = abs(to.y - from.y)
        if pointer.fromKeys && width < 4 && height < 4 {
            // The keyboard sends a click, which gets a box of the usual size.
            let size = viewer.pageSize(page)
            from = ViewPoint(max(0, min(from.x, size.width - Self.keyBox.width)), max(0, min(from.y, size.height - Self.keyBox.height)))
            to = ViewPoint(min(from.x + Self.keyBox.width, size.width), min(from.y + Self.keyBox.height, size.height))
            width = to.x - from.x
            height = to.y - from.y
            draw(to)
        }
        if width < 4 || height < 4 {
            clear()
            return
        }
        box = CropBox(page: page, area: DisplayRect(min(from.x, to.x), min(from.y, to.y), width, height))
        onChange?()
    }

    public func cancel() {
        if dragging { clear() }
    }

    public func clear() {
        dragging = false
        if page >= 0 && page < viewer.pageCount { viewer.overlay(page).remove(Self.id) }
        page = -1
        if box == nil { return }
        box = nil
        onChange?()
    }

    private func inside(_ pointer: PagePointer) -> ViewPoint {
        let size = viewer.pageSize(page)
        return ViewPoint(min(max(pointer.point.x, 0), size.width), min(max(pointer.point.y, 0), size.height))
    }

    private func draw(_ to: ViewPoint) {
        let style = OverlayStyle(stroke: .accent, fill: OverlayColor.accent.opacity(0.15), lineWidth: 1.5, dash: [4, 3])
        viewer.overlay(page).set(OverlayItem(Self.id, .rect(ViewRect(from: from, to: to)), style: style))
    }
}
