import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionGeometry.cs: a marked area as a convex polygon in page user space, and the
// geometry the scan tests it with.
//
// Enumerable.Min, Max and Average of doubles give NaN when one is NaN, and an ordering by a NaN key puts it first; the
// helpers below do the same, so that a NaN meets a mark (the comparisons then all fail and the test falls to "contains")
// instead of being skipped.

typealias MarkPoint = (x: Double, y: Double)

/// A marked area as a convex polygon in page user space, counter-clockwise.
final class MarkArea {
    let points: [MarkPoint]
    let bounds: PdfRect
    let area: Double

    init(_ corners: [MarkPoint]) {
        let cx = Geometry.average(corners.map { $0.x }), cy = Geometry.average(corners.map { $0.y })
        // OrderBy is stable, and sorts a NaN key before the others.
        let keyed = corners.enumerated().map { (index: $0.offset, key: atan2($0.element.y - cy, $0.element.x - cx), point: $0.element) }
        let ordered = keyed.sorted { a, b in
            if a.key.isNaN || b.key.isNaN {
                if a.key.isNaN && b.key.isNaN { return a.index < b.index }
                return a.key.isNaN
            }
            return a.key != b.key ? a.key < b.key : a.index < b.index
        }.map { $0.point }
        points = ordered
        bounds = PdfRect(Geometry.minimum(ordered.map { $0.x }), Geometry.minimum(ordered.map { $0.y }),
                         Geometry.maximum(ordered.map { $0.x }), Geometry.maximum(ordered.map { $0.y }))
        area = Geometry.area(ordered)
    }

    var isUsable: Bool { area > 1e-6 }

    static func of(_ q: TextQuad) -> MarkArea {
        MarkArea([(q.x0, q.y0), (q.x1, q.y1), (q.x2, q.y2), (q.x3, q.y3)])
    }
}

enum Geometry {
    // A glyph box is the font's ascent to descent, wider than the ink and overlapping the lines above
    // and below in tight text. Only its middle is tested, so a mark drawn round a word does not take
    // its neighbours, while one that crosses a glyph at all does.
    private static let core = 0.7

    static func minimum(_ values: [Double]) -> Double {
        var result = Double.infinity
        for (i, v) in values.enumerated() {
            if v.isNaN { return v }
            if i == 0 || v < result { result = v }
        }
        return result
    }

    static func maximum(_ values: [Double]) -> Double {
        var result = -Double.infinity
        for (i, v) in values.enumerated() {
            if v.isNaN { return v }
            if i == 0 || v > result { result = v }
        }
        return result
    }

    static func average(_ values: [Double]) -> Double {
        var sum = 0.0
        for v in values { sum += v }
        return sum / Double(values.count)
    }

    static func area(_ p: [MarkPoint]) -> Double {
        var sum = 0.0
        for i in 0..<p.count {
            let (a, b) = (p[i], p[(i + 1) % p.count])
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    static func contains(_ area: MarkArea, _ x: Double, _ y: Double) -> Bool {
        let p = area.points
        for i in 0..<p.count {
            let (a, b) = (p[i], p[(i + 1) % p.count])
            if (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x) < -1e-9 { return false }
        }
        return true
    }

    /// The part of a polygon inside the area (Sutherland-Hodgman); empty when they miss.
    static func clip(_ subject: [MarkPoint], _ area: MarkArea) -> [MarkPoint] {
        var output = subject
        let clip = area.points
        var i = 0
        while i < clip.count && !output.isEmpty {
            let (a, b) = (clip[i], clip[(i + 1) % clip.count])
            let input = output
            output = []
            for j in 0..<input.count {
                let (cur, prev) = (input[j], input[(j + input.count - 1) % input.count])
                let sc = side(a, b, cur), sp = side(a, b, prev)
                if sc >= 0 {
                    if sp < 0 { output.append(cut(prev, cur, sp, sc)) }
                    output.append(cur)
                } else if sp >= 0 {
                    output.append(cut(prev, cur, sp, sc))
                }
            }
            i += 1
        }
        return output
    }

    private static func side(_ a: MarkPoint, _ b: MarkPoint, _ p: MarkPoint) -> Double {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }

    private static func cut(_ p: MarkPoint, _ q: MarkPoint, _ sp: Double, _ sq: Double) -> MarkPoint {
        let t = sp / (sp - sq)
        return (p.x + t * (q.x - p.x), p.y + t * (q.y - p.y))
    }

    /// The polygon and the area share some surface (a polygon with none is tested at its centre).
    static func overlaps(_ polygon: [MarkPoint], _ area: MarkArea) -> Bool {
        if polygon.isEmpty { return false }
        let whole = Self.area(polygon)
        let extent = nanMax(maximum(polygon.map { $0.x }) - minimum(polygon.map { $0.x }), maximum(polygon.map { $0.y }) - minimum(polygon.map { $0.y }))
        // The thresholds follow the size of the shape, so that a glyph at a tiny font size is not lost between them.
        if whole > 1e-9 * extent * extent { return Self.area(clip(polygon, area)) > nanMin(1e-7, whole * 1e-6) }
        return contains(area, average(polygon.map { $0.x }), average(polygon.map { $0.y }))
    }

    static func glyphMeets(_ box: [MarkPoint], _ area: MarkArea) -> Bool {
        let cx = average(box.map { $0.x }), cy = average(box.map { $0.y })
        return overlaps(box.map { (cx + core * ($0.x - cx), cy + core * ($0.y - cy)) }, area)
    }

    static func corners(_ m: PdfMatrix, _ left: Double, _ bottom: Double, _ right: Double, _ top: Double) -> [MarkPoint] {
        [m.transform(left, bottom), m.transform(right, bottom), m.transform(right, top), m.transform(left, top)]
    }

    static func corners(_ q: TextQuad) -> [MarkPoint] { [(q.x0, q.y0), (q.x1, q.y1), (q.x2, q.y2), (q.x3, q.y3)] }

    /// As `meets`, and a rectangle with no extent counts at the point or line it is.
    static func touches(_ rect: PdfRect, _ area: MarkArea) -> Bool {
        overlaps([(rect.left, rect.bottom), (rect.right, rect.bottom), (rect.right, rect.top), (rect.left, rect.top)], area)
    }

    static func meets(_ rect: PdfRect, _ area: MarkArea) -> Bool {
        !rect.isEmpty && overlaps([(rect.left, rect.bottom), (rect.right, rect.bottom), (rect.right, rect.top), (rect.left, rect.top)], area)
    }

    /// Distance between a segment and the area, zero when they touch.
    static func distance(_ a: MarkPoint, _ b: MarkPoint, _ area: MarkArea) -> Double {
        if contains(area, a.x, a.y) || contains(area, b.x, b.y) { return 0 }
        let p = area.points
        var best = Double.greatestFiniteMagnitude
        for i in 0..<p.count {
            let (c, d) = (p[i], p[(i + 1) % p.count])
            if crosses(a, b, c, d) { return 0 }
            best = nanMin(best, nanMin(nanMin(toSegment(a, c, d), toSegment(b, c, d)), nanMin(toSegment(c, a, b), toSegment(d, a, b))))
        }
        return best
    }

    private static func crosses(_ a: MarkPoint, _ b: MarkPoint, _ c: MarkPoint, _ d: MarkPoint) -> Bool {
        let d1 = side(a, b, c), d2 = side(a, b, d), d3 = side(c, d, a), d4 = side(c, d, b)
        return d1 * d2 < 0 && d3 * d4 < 0
    }

    private static func toSegment(_ p: MarkPoint, _ a: MarkPoint, _ b: MarkPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length == 0 ? 0 : PdfFunction.clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / length, 0, 1)
        return (pow(p.x - (a.x + t * dx), 2) + pow(p.y - (a.y + t * dy), 2)).squareRoot()
    }

    /// Whether the fill of a path (all its subpaths, closed) has the point inside.
    static func inside(_ subpaths: [[MarkPoint]], _ evenOdd: Bool, _ x: Double, _ y: Double) -> Bool {
        var winding = 0, crossings = 0
        for path in subpaths {
            for i in 0..<path.count {
                let (a, b) = (path[i], path[(i + 1) % path.count])
                if (a.y <= y) == (b.y <= y) { continue }
                let at = a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)
                if at <= x { continue }
                crossings += 1
                winding += b.y > a.y ? 1 : -1
            }
        }
        return evenOdd ? crossings % 2 == 1 : winding != 0
    }
}
