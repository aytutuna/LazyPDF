import Foundation

// Twin of windows/LazyPDF.Core/Forms/PageScan.cs: what a page draws that matters to finding blanks: glyphs, ruling lines,
// boxes and circles, all in user space.

struct ScanGlyph {
    let box: PdfRect
    let text: String
}

struct ScanRun {
    let box: PdfRect
    let text: String
    let glyphs: [ScanGlyph]
}

/// LINQ's OrderBy is stable and Swift's `sorted` does not promise to be: equal elements keep their order here.
func stableSorted<T>(_ items: [T], _ less: (T, T) -> Bool) -> [T] {
    items.enumerated().sorted { a, b in
        if less(a.element, b.element) { return true }
        if less(b.element, a.element) { return false }
        return a.offset < b.offset
    }.map { $0.element }
}

final class PageScan: ContentVisitor {
    private static let maxItems = 200_000
    private static let thin = 1.6
    private static let tolerance = 0.6

    var glyphs: [ScanGlyph] = []
    var horizontal: [(y: Double, x1: Double, x2: Double)] = []
    var vertical: [(x: Double, y1: Double, y2: Double)] = []
    var boxes: [PdfRect] = []
    var circles: [PdfRect] = []

    override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
        if glyphs.count < Self.maxItems, let text = glyph.unicode, !text.isEmpty, context.state.renderMode != 3, !glyph.bounds.isEmpty {
            glyphs.append(ScanGlyph(box: glyph.bounds, text: text))
        }
    }

    override func paintPath(_ context: ContentContext, _ path: PathInfo) {
        if !path.fill && !path.stroke { return }
        // A filled shape that is not light is a bar or a picture, not an empty box.
        let rgb = context.state.fillColor.rgb
        let light = !path.fill || path.stroke || Double(Int(rgb.r) + Int(rgb.g) + Int(rgb.b)) / 3.0 > 217
        let curves = path.segments.filter { $0.kind == .curve }.count
        if curves >= 4 && curves <= 8 && path.segments.allSatisfy({ $0.kind != .line }) {
            circle(path.bounds)
            return
        }
        for points in Self.subpaths(path.segments) {
            if horizontal.count + boxes.count + vertical.count >= Self.maxItems { return }
            if points.count == 2 && path.stroke {
                line(points[0], points[1])
            } else if points.count == 4 || points.count == 5, let box = Self.rectangle(points) {
                shape(box, light)
            }
        }
    }

    private func line(_ a: PdfPoint, _ b: PdfPoint) {
        if abs(a.y - b.y) <= Self.tolerance && abs(a.x - b.x) >= 8 {
            horizontal.append(((a.y + b.y) / 2, min(a.x, b.x), max(a.x, b.x)))
        } else if abs(a.x - b.x) <= Self.tolerance && abs(a.y - b.y) >= 8 {
            vertical.append(((a.x + b.x) / 2, min(a.y, b.y), max(a.y, b.y)))
        }
    }

    private func shape(_ box: PdfRect, _ light: Bool) {
        if box.height <= Self.thin && box.width >= 8 {
            horizontal.append(((box.bottom + box.top) / 2, box.left, box.right))
        } else if box.width <= Self.thin && box.height >= 8 {
            vertical.append(((box.left + box.right) / 2, box.bottom, box.top))
        } else if light && box.width >= 5 && box.height >= 5 {
            boxes.append(box)
        }
    }

    private func circle(_ bounds: PdfRect) {
        if bounds.width >= 5 && bounds.width <= 24 && abs(bounds.width - bounds.height) <= 0.15 * bounds.width { circles.append(bounds) }
    }

    private static func rectangle(_ points: [PdfPoint]) -> PdfRect? {
        if points.count == 5 && (abs(points[4].x - points[0].x) > tolerance || abs(points[4].y - points[0].y) > tolerance) { return nil }
        let corners = Array(points.prefix(4))
        guard let minX = corners.map({ $0.x }).min(), let minY = corners.map({ $0.y }).min(),
              let maxX = corners.map({ $0.x }).max(), let maxY = corners.map({ $0.y }).max() else { return nil }
        let box = PdfRect(minX, minY, maxX, maxY)
        let all = corners.allSatisfy { p in
            (abs(p.x - box.left) <= tolerance || abs(p.x - box.right) <= tolerance)
                && (abs(p.y - box.bottom) <= tolerance || abs(p.y - box.top) <= tolerance)
        }
        return all ? box : nil
    }

    private static func subpaths(_ segments: [PathSegment]) -> [[PdfPoint]] {
        var result: [[PdfPoint]] = []
        for s in segments {
            switch s.kind {
            case .move:
                result.append([(s.x1, s.y1)])
            case .line:
                if !result.isEmpty { result[result.count - 1].append((s.x1, s.y1)) }
            default:
                break
            }
        }
        return result
    }

    /// Glyphs in drawing order cut into runs: a new run starts on another line or after a gap wider than half the line height.
    func runs() -> [ScanRun] {
        var runs: [ScanRun] = []
        var current: [ScanGlyph] = []
        func flush() {
            if current.isEmpty { return }
            let box = PdfRect(current.map { $0.box.left }.min() ?? 0, current.map { $0.box.bottom }.min() ?? 0,
                              current.map { $0.box.right }.max() ?? 0, current.map { $0.box.top }.max() ?? 0)
            runs.append(ScanRun(box: box, text: current.map { $0.text }.joined(), glyphs: current))
            current.removeAll()
        }
        for g in glyphs {
            if let last = current.last?.box {
                let height = max(last.height, g.box.height)
                let sameLine = abs((last.bottom + last.top) / 2 - (g.box.bottom + g.box.top) / 2) <= 0.4 * height
                let gap = g.box.left - last.right
                if !sameLine || gap > 0.5 * height || gap < -height { flush() }
            }
            current.append(g)
        }
        flush()
        return runs
    }
}
