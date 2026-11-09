import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Measure/MeasureOverlay.cs: draws the measurements waiting to be written and the one being
// drawn on the pages' overlay layers, as items under "measure.".

@MainActor
final class MeasureOverlay {
    static let prefix = "measure."
    private static let ink = OverlayColor(red: 13.0 / 255, green: 97.0 / 255, blue: 191.0 / 255)
    private static let halo = OverlayColor(red: 1, green: 1, blue: 1, alpha: 200.0 / 255)
    private static let wash = OverlayColor(red: 13.0 / 255, green: 97.0 / 255, blue: 191.0 / 255, alpha: 40.0 / 255)

    private let viewer: DocumentViewer
    private let tool: MeasureTool
    private var pages = Set<Int>()
    private var drawn = 0

    init(viewer: DocumentViewer, tool: MeasureTool) {
        self.viewer = viewer
        self.tool = tool
    }

    func clear() {
        for page in pages where page < viewer.pageCount { viewer.overlay(page).remove(prefix: Self.prefix) }
        pages.removeAll()
        drawn = 0
    }

    func draw(_ items: [MeasureItem], _ scale: MeasureScale) {
        clear()
        for item in items {
            shape(item.page, item.points, closed: item.kind != .distance, dashed: false, filled: item.kind == .area,
                  label: item.value(scale), at: item.middle)
        }
        if tool.page >= 0, let last = tool.points.last {
            var points = tool.points
            let live = tool.hoverPage == tool.page && tool.hover != nil
            if live, let hover = tool.hover { points.append(hover) }
            let closed = tool.kind != .distance && points.count > 2
            let text = points.count > 1 ? MeasureItem(tool.kind, tool.page, points).value(scale) : nil
            shape(tool.page, points, closed: closed, dashed: live, filled: closed && tool.kind == .area, label: text, at: points.last ?? last)
        }
        if tool.snapped, let at = tool.hover { marker(tool.hoverPage, at) }
    }

    private func layer(_ page: Int) -> PageOverlay? {
        guard page >= 0, page < viewer.pageCount, tool.scale(page) > 0 else { return nil }
        pages.insert(page)
        return viewer.overlay(page)
    }

    private func shape(_ page: Int, _ points: [ViewPoint], closed: Bool, dashed: Bool, filled: Bool, label: String?, at: ViewPoint) {
        guard !points.isEmpty, let layer = layer(page) else { return }
        let scale = tool.scale(page)
        let id = Self.prefix + "\(drawn)."
        drawn += 1
        layer.set(OverlayItem(id + "halo", .path(points, closed: closed), style: OverlayStyle(stroke: Self.halo, lineWidth: 4.5, round: true)))
        layer.set(OverlayItem(id + "ink", .path(points, closed: closed),
                              style: OverlayStyle(stroke: Self.ink, fill: filled ? Self.wash : nil, lineWidth: 1.5, dash: dashed ? [4, 3] : [], round: true)))
        for (i, point) in points.enumerated() {
            layer.set(OverlayItem(id + "dot.\(i)", .marker(center: point, size: 6, round: true), style: OverlayStyle(stroke: Self.halo, fill: Self.ink, lineWidth: 1)))
        }
        guard let label else { return }
        let text = OverlayText(label, at: ViewPoint(at.x + 6 / scale, at.y - 18 / scale), look: OverlayTextLook(size: 12, color: Self.ink),
                               sizeOnScreen: true, background: Self.halo)
        layer.set(OverlayItem(id + "label", .text(text)))
    }

    private func marker(_ page: Int, _ at: ViewPoint) {
        layer(page)?.set(OverlayItem(Self.prefix + "snap", .marker(center: at, size: 10, round: false), style: OverlayStyle(stroke: Self.ink, lineWidth: 1.5)))
    }
}
