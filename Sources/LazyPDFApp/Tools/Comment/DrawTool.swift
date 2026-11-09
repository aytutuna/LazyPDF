import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Comment/DrawTool.cs: takes the pointer to draw one kind of mark on a page; what was drawn
// goes to `done` as page points. The preview is overlay items under "comment.".

@MainActor
final class DrawTool: PagePointerTool {
    static let previewId = "comment.preview"
    static let boxId = "comment.box"
    private static let minDrag = 3.0
    private static let defaultBox = ViewSize(160, 48)

    private let viewer: DocumentViewer
    private let tool: MarkTool
    private let style: () -> MarkStyle
    private let done: (MarkTool, Int, [ViewPoint]) -> Void
    private var points: [ViewPoint] = []
    private var page = -1
    private var now = ViewPoint.zero

    /// Called when a shape was started, finished or dropped, for the button that finishes a polygon.
    var changed: (() -> Void)?

    init(viewer: DocumentViewer, tool: MarkTool, style: @escaping () -> MarkStyle, done: @escaping (MarkTool, Int, [ViewPoint]) -> Void) {
        self.viewer = viewer
        self.tool = tool
        self.style = style
        self.done = done
    }

    var cursor: PointerCursor? { .crosshair }

    /// A polygon or cloud has corners and waits for more.
    var started: Bool { page >= 0 }

    /// A polygon or cloud with corners enough to be finished.
    var canFinish: Bool { many && started && points.count >= 3 }

    private var byClick: Bool { tool == .note || tool == .stamp || tool == .attach }

    private var many: Bool { tool == .polygon || tool == .cloud }

    func key(_ key: ViewerKey, modifiers: PointerModifiers) -> Bool {
        guard key == .escape, started else { return false }
        cancel()
        return true
    }

    func press(_ pointer: PagePointer) {
        if many && page >= 0 {
            if pointer.page != page { return }
            if pointer.clicks >= 2 || (points.count >= 3 && Self.close(pointer.point, points[0])) {
                finish()
            } else {
                extend(pointer.point)
            }
            return
        }
        clear()
        page = pointer.page
        points.append(pointer.point)
        now = pointer.point
        if !byClick { show() }
        changed?()
    }

    func move(_ pointer: PagePointer) {
        guard page >= 0, pointer.page == page else { return }
        now = pointer.point
        if pointer.pressed && (tool == .pencil || tool == .eraser), let last = points.last, Self.distance(now, last) >= 1 {
            points.append(now)
        }
        show()
    }

    func release(_ pointer: PagePointer) {
        guard page >= 0 else { return }
        if pointer.page == page { now = pointer.point }
        if many {
            if points.count == 1 { extend(now) }
            return
        }
        if byClick {
            finish()
            return
        }
        if tool == .pencil || tool == .eraser {
            if points.count < 2 { points.append(ViewPoint(now.x + 0.1, now.y)) }
            finish()
            return
        }
        if Self.distance(now, points[0]) < Self.minDrag {
            // A click makes a box of the usual size, so the keyboard can place one too.
            if tool != .textBox {
                clear()
                changed?()
                return
            }
            let size = viewer.pageSize(page)
            now = ViewPoint(min(points[0].x + Self.defaultBox.width, size.width), min(points[0].y + Self.defaultBox.height, size.height))
        }
        points.append(now)
        finish()
    }

    func cancel() {
        clear()
        changed?()
    }

    /// Ends a polygon or cloud at the corner it has, as a double click does.
    func finishShape() {
        if canFinish { finish() }
    }

    private static func close(_ a: ViewPoint, _ b: ViewPoint) -> Bool { distance(a, b) < 6 }

    private static func distance(_ a: ViewPoint, _ b: ViewPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    private func extend(_ at: ViewPoint) {
        if let last = points.last, Self.distance(at, last) < 1 { return }
        points.append(at)
        show()
        changed?()
    }

    private func finish() {
        let drawnPage = page
        let drawn = points
        clear()
        changed?()
        if many && drawn.count < 3 { return }
        done(tool, drawnPage, drawn)
    }

    private func clear() {
        if page >= 0 {
            let overlay = viewer.overlay(page)
            overlay.remove(Self.previewId)
            overlay.remove(Self.boxId)
        }
        points.removeAll()
        page = -1
    }

    // The preview is redrawn whole on every move: the shapes are small and a page rarely holds more than a few points.
    private func show() {
        guard page >= 0, let first = points.first else { return }
        let overlay = viewer.overlay(page)
        let look = style()
        let rgb = Marker.rgb(of: look.color) ?? [0, 0, 0]
        let color = look.color == nil ? OverlayColor(red: 1, green: 0, blue: 0)
            : OverlayColor(red: rgb[0], green: rgb[1], blue: rgb[2])
        let eraser = tool == .eraser
        let ink = eraser ? OverlayColor(red: 0.5, green: 0.5, blue: 0.5) : color
        let opacity = eraser ? 0.5 : look.opacity
        let thickness = eraser ? 8 : max(look.width, 1)

        let stroke = { (width: Double, dash: [Double], round: Bool) in
            OverlayStyle(stroke: ink, lineWidth: width, scalesWithPage: true, dash: dash, round: round)
        }
        let outline: OverlayItem?
        switch tool {
        case .rectangle, .textBox:
            outline = OverlayItem(Self.previewId, .rect(ViewRect(from: first, to: now)),
                                  style: stroke(tool == .textBox ? 1 : thickness, tool == .textBox ? [4, 3] : [], false), opacity: opacity)
        case .oval:
            outline = OverlayItem(Self.previewId, .ellipse(ViewRect(from: first, to: now)), style: stroke(thickness, [], false), opacity: opacity)
        case .line, .arrow, .callout:
            outline = OverlayItem(Self.previewId, .line(first, now), style: stroke(thickness, [], false), opacity: opacity)
        case .polygon, .cloud:
            outline = OverlayItem(Self.previewId, .path(points + [now], closed: false), style: stroke(thickness, [], true), opacity: opacity)
        case .pencil, .eraser:
            outline = OverlayItem(Self.previewId, .path(points, closed: false), style: stroke(thickness, [], true), opacity: opacity)
        default:
            outline = nil
        }
        guard let outline else {
            overlay.remove(Self.previewId)
            return
        }
        overlay.set(outline)
        if tool == .callout {
            overlay.set(OverlayItem(Self.boxId, .rect(Marker.box(for: tool, [first, now])), style: stroke(thickness, [], false), opacity: opacity))
        }
    }
}
