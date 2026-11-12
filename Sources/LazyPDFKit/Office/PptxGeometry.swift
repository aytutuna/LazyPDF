import Foundation

// Twin of windows/LazyPDF.Core/Office/Pptx/PptxGeometry.cs.

/// A plane transform: x' = a x + c y + e, y' = b x + d y + f.
struct Affine: Equatable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    static let identity = Affine()

    static func translate(_ x: Double, _ y: Double) -> Affine { Affine(a: 1, b: 0, c: 0, d: 1, e: x, f: y) }

    static func scale(_ x: Double, _ y: Double) -> Affine { Affine(a: x, b: 0, c: 0, d: y, e: 0, f: 0) }

    /// A turn clockwise on a page whose y runs down. Right angles are exact.
    static func rotate(_ degrees: Double) -> Affine {
        var degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        let cos: Double, sin: Double
        if degrees == 0 {
            (cos, sin) = (1, 0)
        } else if degrees == 90 {
            (cos, sin) = (0, 1)
        } else if degrees == 180 {
            (cos, sin) = (-1, 0)
        } else if degrees == 270 {
            (cos, sin) = (0, -1)
        } else {
            cos = Foundation.cos(degrees * Double.pi / 180)
            sin = Foundation.sin(degrees * Double.pi / 180)
        }
        return Affine(a: cos, b: sin, c: -sin, d: cos, e: 0, f: 0)
    }

    /// The transform that applies `first` and then this one.
    func multiply(_ first: Affine) -> Affine {
        Affine(a: a * first.a + c * first.b, b: b * first.a + d * first.b,
               c: a * first.c + c * first.d, d: b * first.c + d * first.d,
               e: a * first.e + c * first.f + e, f: b * first.e + d * first.f + f)
    }

    static func length(_ x: Double, _ y: Double) -> Double { (x * x + y * y).squareRoot() }

    func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) { (a * x + c * y + e, b * x + d * y + f) }
}

/// The preset shapes of DrawingML that slides use most, as outlines in a box of width w and height h with the corner at 0, 0,
/// following the formulas of the presetShapeDefinitions of ECMA-376. Adjust values are in hundredths of a percent as the file
/// states them.
enum PptxGeometry {
    private static let kappa = 0.5522847498307936

    private static let presets: Set<String> = [
        "rect", "roundRect", "ellipse", "triangle", "rtTriangle", "diamond", "parallelogram", "trapezoid", "pentagon", "hexagon", "octagon",
        "chevron", "homePlate", "star5", "rightArrow", "leftArrow", "upArrow", "downArrow", "line", "straightConnector1",
    ]

    static func supports(_ preset: String) -> Bool { presets.contains(preset) }

    static func isLine(_ preset: String) -> Bool { preset == "line" || preset == "straightConnector1" }

    static func build(_ preset: String, _ w: Double, _ h: Double, _ adjust: [String: Double]) -> [PathCommand] {
        func adj(_ name: String, _ fallback: Double, _ top: Double = 100_000) -> Double { min(max(adjust[name] ?? fallback, 0), top) }
        let ss = min(w, h)
        switch preset {
        case "line", "straightConnector1":
            return [.move(0, 0), .line(w, h)]
        case "roundRect":
            let r = ss * adj("adj", 16667, 50_000) / 100_000, k = r * kappa
            return [
                .move(r, 0), .line(w - r, 0), .curve(w - r + k, 0, w, r - k, w, r),
                .line(w, h - r), .curve(w, h - r + k, w - r + k, h, w - r, h),
                .line(r, h), .curve(r - k, h, 0, h - r + k, 0, h - r),
                .line(0, r), .curve(0, r - k, r - k, 0, r, 0), .close,
            ]
        case "ellipse":
            return ellipse(w / 2, h / 2, w / 2, h / 2)
        case "triangle":
            return polygon([(0, h), (w * adj("adj", 50_000) / 100_000, 0), (w, h)])
        case "rtTriangle":
            return polygon([(0, h), (0, 0), (w, h)])
        case "diamond":
            return polygon([(0, h / 2), (w / 2, 0), (w, h / 2), (w / 2, h)])
        case "parallelogram":
            let x = ss * adj("adj", 25_000, ss > 0 ? 100_000 * w / ss : 0) / 100_000
            return polygon([(0, h), (x, 0), (w, 0), (w - x, h)])
        case "trapezoid":
            let x = ss * adj("adj", 25_000, ss > 0 ? 50_000 * w / ss : 0) / 100_000
            return polygon([(0, h), (x, 0), (w - x, 0), (w, h)])
        case "pentagon":
            return star(5, w, h, 1, 1.05146, 1.10557)
        case "star5":
            return star(5, w, h, adj("adj", 19098, 50_000) / 50_000, 1.05146, 1.10557)
        case "hexagon":
            let x = ss * adj("adj", 25_000, ss > 0 ? 50_000 * w / ss : 0) / 100_000
            return polygon([(0, h / 2), (x, 0), (w - x, 0), (w, h / 2), (w - x, h), (x, h)])
        case "octagon":
            let x = ss * adj("adj", 29289, 50_000) / 100_000
            return polygon([(0, x), (x, 0), (w - x, 0), (w, x), (w, h - x), (w - x, h), (x, h), (0, h - x)])
        case "chevron":
            let x = ss * adj("adj", 50_000, ss > 0 ? 100_000 * w / ss : 0) / 100_000
            return polygon([(0, 0), (w - x, 0), (w, h / 2), (w - x, h), (0, h), (x, h / 2)])
        case "homePlate":
            let x = w - ss * adj("adj", 50_000, ss > 0 ? 100_000 * w / ss : 0) / 100_000
            return polygon([(0, 0), (x, 0), (w, h / 2), (x, h), (0, h)])
        case "rightArrow":
            return arrow(w, h, adj("adj1", 50_000), adjust, false, false)
        case "leftArrow":
            return arrow(w, h, adj("adj1", 50_000), adjust, true, false)
        case "downArrow":
            return arrow(h, w, adj("adj1", 50_000), adjust, false, true)
        case "upArrow":
            return arrow(h, w, adj("adj1", 50_000), adjust, true, true)
        default:
            return polygon([(0, 0), (w, 0), (w, h), (0, h)])
        }
    }

    private static func polygon(_ points: [(Double, Double)]) -> [PathCommand] {
        var list: [PathCommand] = []
        list.reserveCapacity(points.count + 1)
        for (i, p) in points.enumerated() { list.append(i == 0 ? .move(p.0, p.1) : .line(p.0, p.1)) }
        list.append(.close)
        return list
    }

    private static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> [PathCommand] {
        let kx = rx * kappa, ky = ry * kappa
        return [
            .move(cx - rx, cy),
            .curve(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry),
            .curve(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy),
            .curve(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry),
            .curve(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy),
            .close,
        ]
    }

    // The outline of an n-pointed star: the points on the ellipse of the box (stretched by hf and vf as the definitions do so
    // that the points touch its edges) and the inner corners at the fraction `inner` of that radius, half a step between.
    private static func star(_ points: Int, _ w: Double, _ h: Double, _ inner: Double, _ hf: Double, _ vf: Double) -> [PathCommand] {
        let rx = w / 2 * hf, ry = h / 2 * vf, cx = w / 2, cy = h / 2 * vf
        var list: [PathCommand] = []
        let count = inner < 1 ? points * 2 : points
        for i in 0..<count {
            let angle = (-90 + 360.0 * Double(i) / Double(count)) * Double.pi / 180
            let scale = inner < 1 && i % 2 == 1 ? inner : 1
            let x = cx + rx * scale * cos(angle), y = cy + ry * scale * sin(angle)
            list.append(i == 0 ? .move(x, y) : .line(x, y))
        }
        list.append(.close)
        return list
    }

    // An arrow pointing right in a box of length x thickness, mirrored for left, and turned into the other axis for up and down.
    private static func arrow(_ length: Double, _ thickness: Double, _ shaft: Double, _ adjust: [String: Double], _ reverse: Bool, _ vertical: Bool) -> [PathCommand] {
        let ss = min(length, thickness)
        let maxHead = ss > 0 ? 100_000 * length / ss : 0
        let head = ss * min(max(adjust["adj2"] ?? 50_000, 0), maxHead) / 100_000
        let half = thickness * shaft / 200_000, mid = thickness / 2, x = length - head
        var points: [(Double, Double)] = [
            (0, mid - half), (x, mid - half), (x, 0), (length, mid), (x, thickness), (x, mid + half), (0, mid + half),
        ]
        for i in 0..<points.count {
            var (px, py) = points[i]
            if reverse { px = length - px }
            points[i] = vertical ? (py, px) : (px, py)
        }
        return polygon(points)
    }
}
