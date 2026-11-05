import Foundation

// Twin of windows/LazyPDF.Core/Annotations/CloudBorder.cs: the scalloped border of /BE /S /C (ISO 32000-1 12.5.4): a
// closed path replaced by a chain of outward arcs.

/// A point in user space (the C# writes it as a (double X, double Y) tuple).
public typealias PdfPoint = (x: Double, y: Double)

enum CloudBorder {
    private static let maxPoints = 20_000

    static func spacing(_ intensity: Int) -> Double { 6 + 4 * Double(min(max(intensity, 1), 2)) }

    /// How far an arc bulges out of the path it replaces.
    static func bulge(_ intensity: Int) -> Double { spacing(intensity) * 0.4 }

    /// The corners with the edges cut into pieces about `spacing` long, so that every corner stays a join between two arcs.
    static func resample(_ corners: [PdfPoint], _ spacing: Double) -> [PdfPoint] {
        var perimeter = 0.0
        for i in 0..<corners.count { perimeter += distance(corners[i], corners[(i + 1) % corners.count]) }
        // Math.Max gives NaN when either side is NaN (an infinite edge), where Swift's max drops a NaN second argument;
        // with a NaN spacing every edge is one piece, so the count stays bounded.
        let least = perimeter / Double(maxPoints)
        let spacing = least.isNaN ? least : max(spacing, least)
        var points: [PdfPoint] = []
        for i in 0..<corners.count {
            let p = corners[i]
            let q = corners[(i + 1) % corners.count]
            let pieces = max(1, Int(saturating32: (distance(p, q) / spacing).rounded(.up)))
            for k in 0..<pieces {
                let t = Double(k) / Double(pieces)
                points.append((p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t))
            }
        }
        return points
    }

    /// Points equally far apart along the ellipse's own length, at most `spacing` apart.
    static func ellipsePoints(_ left: Double, _ bottom: Double, _ right: Double, _ top: Double, _ spacing: Double) -> [PdfPoint] {
        let steps = 720
        let cx = (left + right) / 2, cy = (bottom + top) / 2, rx = (right - left) / 2, ry = (top - bottom) / 2
        var dense: [PdfPoint] = []
        var length = [Double](repeating: 0, count: steps + 1)
        for i in 0...steps {
            let angle = 2 * Double.pi * Double(i) / Double(steps)
            dense.append((cx + rx * cos(angle), cy + ry * sin(angle)))
            if i > 0 { length[i] = length[i - 1] + distance(dense[i - 1], dense[i]) }
        }
        let count = Int(saturating32: min(max((length[steps] / spacing).rounded(.up), 6), Double(maxPoints)))
        var points: [PdfPoint] = []
        points.reserveCapacity(count)
        var at = 0
        for k in 0..<count {
            let target = length[steps] * Double(k) / Double(count)
            while at < steps - 1 && length[at + 1] < target { at += 1 }
            let span = length[at + 1] - length[at]
            let t = span > 0 ? (target - length[at]) / span : 0
            points.append((dense[at].x + (dense[at + 1].x - dense[at].x) * t, dense[at].y + (dense[at + 1].y - dense[at].y) * t))
        }
        return points
    }

    static func rectPoints(_ left: Double, _ bottom: Double, _ right: Double, _ top: Double, _ spacing: Double) -> [PdfPoint] {
        resample([(left, bottom), (right, bottom), (right, top), (left, top)], spacing)
    }

    /// Adds the closed scalloped path of the points, which must run once around the shape.
    static func draw(_ canvas: AppearanceCanvas, _ points: [PdfPoint]) {
        if points.count < 3 { return }
        var area = 0.0
        for i in 0..<points.count {
            let (x1, y1) = points[i]
            let (x2, y2) = points[(i + 1) % points.count]
            area += x1 * y2 - x2 * y1
        }
        // Outward is to the right of a counter-clockwise walk, to the left of a clockwise one.
        let side = area >= 0 ? 1.0 : -1.0
        canvas.move(points[0].x, points[0].y)
        for i in 0..<points.count {
            let p = points[i]
            let q = points[(i + 1) % points.count]
            let length = distance(p, q)
            if length < 1e-6 { continue }
            // A cubic whose handles stand 4/3 of the height out peaks at that height.
            let h = length * 0.4 * 4 / 3
            let nx = side * (q.y - p.y) / length * h, ny = -side * (q.x - p.x) / length * h
            canvas.curve(p.x + nx, p.y + ny, q.x + nx, q.y + ny, q.x, q.y)
        }
        canvas.w.close()
    }

    private static func distance(_ p: PdfPoint, _ q: PdfPoint) -> Double {
        ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)).squareRoot()
    }
}
