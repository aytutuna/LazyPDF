import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportScan.cs: collects the images a page paints and, on request, the straight
// lines it draws.

/// A straight rule drawn on the page, in display points: `pos` is y for a horizontal one and x for a vertical one.
struct ExportRule {
    let horizontal: Bool
    let pos: Double
    let from: Double
    let to: Double
}

final class ExportScan: ContentVisitor {
    private static let maxImages = 400
    private static let maxRules = 20000

    // Shorter lines are bullets and dashes, thicker ones shading.
    private static let minRule = 6.0
    private static let maxThickness = 2.5

    private let geometry: PageGeometry
    private let wantRules: Bool

    private(set) var images: [ImageInfo] = []
    private(set) var rules: [ExportRule] = []

    init(_ geometry: PageGeometry, _ wantRules: Bool) {
        self.geometry = geometry
        self.wantRules = wantRules
        super.init()
    }

    override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
        if images.count < Self.maxImages { images.append(image) }
    }

    override func paintPath(_ context: ContentContext, _ path: PathInfo) {
        if !wantRules || rules.count >= Self.maxRules || (!path.fill && !path.stroke) { return }
        if path.fill && !path.stroke {
            let box = geometry.toDisplay(path.bounds)
            if min(box.width, box.height) <= Self.maxThickness && max(box.width, box.height) >= Self.minRule {
                if box.width >= box.height {
                    rules.append(ExportRule(horizontal: true, pos: box.y + box.height / 2, from: box.x, to: box.x + box.width))
                } else {
                    rules.append(ExportRule(horizontal: false, pos: box.x + box.width / 2, from: box.y, to: box.y + box.height))
                }
            }
            return
        }

        var sx = 0.0, sy = 0.0, cx = 0.0, cy = 0.0
        for s in path.segments {
            switch s.kind {
            case .move:
                (sx, sy) = geometry.toDisplay(s.x1, s.y1)
                (cx, cy) = (sx, sy)
            case .line:
                let (lx, ly) = geometry.toDisplay(s.x1, s.y1)
                edge(cx, cy, lx, ly)
                (cx, cy) = (lx, ly)
            case .curve:
                (cx, cy) = geometry.toDisplay(s.x3, s.y3)
            case .close:
                edge(cx, cy, sx, sy)
                (cx, cy) = (sx, sy)
            }
            if rules.count >= Self.maxRules { return }
        }
    }

    private func edge(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        let dx = abs(x2 - x1), dy = abs(y2 - y1)
        if dy <= 0.6 && dx >= Self.minRule {
            rules.append(ExportRule(horizontal: true, pos: (y1 + y2) / 2, from: min(x1, x2), to: max(x1, x2)))
        } else if dx <= 0.6 && dy >= Self.minRule {
            rules.append(ExportRule(horizontal: false, pos: (x1 + x2) / 2, from: min(y1, y2), to: max(y1, y2)))
        }
    }
}
