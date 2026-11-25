import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionPaths.cs: where a painted or clipping path meets the marks, and what is
// left of it outside them.

enum RedactionPaths {
    private static let curveSteps = 8
    private static let maxPieces = 4096
    private static let maxClipWork = 1_000_000

    static func polygons(_ polygons: [[MarkPoint]]) -> String {
        var path = ""
        for polygon in polygons { self.polygon(&path, polygon) }
        return path
    }

    static func polygon(_ path: inout String, _ points: [MarkPoint]) {
        for i in 0..<points.count {
            path += PdfNumber(points[i].x).text + " " + PdfNumber(points[i].y).text + (i == 0 ? " m\n" : " l\n")
        }
        path += "h\n"
    }

    private static func flatten(_ path: PathInfo) -> (subpaths: [[MarkPoint]], closed: [Bool]) {
        var result: [[MarkPoint]] = []
        var closed: [Bool] = []
        var last: MarkPoint = (0, 0)
        for s in path.segments {
            switch s.kind {
            case .move:
                result.append([(s.x1, s.y1)])
                closed.append(false)
                last = (s.x1, s.y1)
            case .line where !result.isEmpty:
                last = (s.x1, s.y1)
                result[result.count - 1].append(last)
            case .curve where !result.isEmpty:
                let start = last
                for i in 1...curveSteps {
                    let t = Double(i) / Double(curveSteps), u = 1 - t
                    result[result.count - 1].append((u * u * u * start.x + 3 * u * u * t * s.x1 + 3 * u * t * t * s.x2 + t * t * t * s.x3,
                                                     u * u * u * start.y + 3 * u * u * t * s.y1 + 3 * u * t * t * s.y2 + t * t * t * s.y3))
                }
                last = (s.x3, s.y3)
            case .close where !result.isEmpty:
                closed[closed.count - 1] = true
                last = result[result.count - 1][0]
            default:
                break
            }
        }
        return (result, closed)
    }

    /// A path that only clips counts as filled: the region it opens is what is tested.
    static func meets(_ path: PathInfo, _ area: MarkArea) -> Bool {
        let ink = path.inkBounds
        if ink.right < area.bounds.left || ink.left > area.bounds.right || ink.top < area.bounds.bottom || ink.bottom > area.bounds.top { return false }
        let fill = path.fill || !path.stroke
        let (subpaths, closed) = flatten(path)
        let half = nanMax(0, (path.inkBounds.width - path.bounds.width) / 2)
        for s in 0..<subpaths.count {
            let points = subpaths[s]
            let wrap = fill || closed[s]
            for i in 0..<points.count {
                if i + 1 == points.count && !wrap { break }
                let reach = Geometry.distance(points[i], points[(i + 1) % points.count], area)
                if fill && reach == 0 { return true }
                if path.stroke && reach <= half { return true }
            }
        }
        if !fill { return false }
        let inside = area.points + [(x: Geometry.average(area.points.map { $0.x }), y: Geometry.average(area.points.map { $0.y }))]
        return inside.contains { Geometry.inside(subpaths, path.evenOdd, $0.x, $0.y) }
    }

    static func axisRectangle(_ path: PathInfo) -> PdfRect? {
        var points: [MarkPoint] = []
        for s in path.segments {
            if s.kind == .move && points.isEmpty {
                points.append((s.x1, s.y1))
            } else if s.kind == .line {
                points.append((s.x1, s.y1))
            } else if s.kind != .close {
                return nil
            }
        }
        if points.count == 5 && near(points[0], points[4]) { points.remove(at: 4) }
        if points.count != 4 { return nil }
        let horizontalFirst = same(points[0].y, points[1].y) && same(points[1].x, points[2].x) && same(points[2].y, points[3].y) && same(points[3].x, points[0].x)
        let verticalFirst = same(points[0].x, points[1].x) && same(points[1].y, points[2].y) && same(points[2].x, points[3].x) && same(points[3].y, points[0].y)
        if !horizontalFirst && !verticalFirst { return nil }
        return PdfRect(Geometry.minimum(points.map { $0.x }), Geometry.minimum(points.map { $0.y }),
                       Geometry.maximum(points.map { $0.x }), Geometry.maximum(points.map { $0.y }))
    }

    /// The rectangle with the boxes of the marks taken out, as polygons.
    static func around(_ rect: PdfRect, _ hit: [MarkArea]) -> [[MarkPoint]] {
        var pieces = [rect]
        for area in hit { pieces = pieces.flatMap { subtract($0, area.bounds) } }
        return pieces.map { corners($0) }
    }

    /// The outline of a clipping path with the boxes of the marks taken out: each subpath, flattened, cut to the rectangles
    /// around the marks. Empty when nothing is left or the work would be too much; the caller then clips to nothing, which
    /// only hides more.
    static func outside(_ path: PathInfo, _ hit: [MarkArea]) -> [[MarkPoint]] {
        var pieces = [path.bounds]
        for area in hit {
            pieces = pieces.flatMap { subtract($0, area.bounds) }
            if pieces.count > maxPieces { return [] }
        }
        let subpaths = flatten(path).subpaths
        var result: [[MarkPoint]] = []
        let (work, overflow) = pieces.count.multipliedReportingOverflow(by: subpaths.count)
        if overflow || work > maxClipWork { return result }
        for piece in pieces {
            let box = MarkArea(corners(piece))
            if !box.isUsable { continue }
            for subpath in subpaths {
                if subpath.count < 3 { continue }
                let cut = Geometry.clip(subpath, box)
                if cut.count >= 3 && Geometry.area(cut) > 1e-9 { result.append(cut) }
            }
        }
        return result
    }

    private static func corners(_ r: PdfRect) -> [MarkPoint] { [(r.left, r.bottom), (r.right, r.bottom), (r.right, r.top), (r.left, r.top)] }

    private static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    private static func near(_ a: MarkPoint, _ b: MarkPoint) -> Bool { same(a.x, b.x) && same(a.y, b.y) }

    // A band to the left and right over the full height and the strips above and below between them.
    private static func subtract(_ r: PdfRect, _ cut: PdfRect) -> [PdfRect] {
        if cut.right <= r.left || cut.left >= r.right || cut.top <= r.bottom || cut.bottom >= r.top { return [r] }
        var pieces: [PdfRect] = []
        let left = nanMax(cut.left, r.left), right = nanMin(cut.right, r.right)
        if cut.left > r.left { pieces.append(PdfRect(r.left, r.bottom, cut.left, r.top)) }
        if cut.right < r.right { pieces.append(PdfRect(cut.right, r.bottom, r.right, r.top)) }
        if cut.top < r.top { pieces.append(PdfRect(left, cut.top, right, r.top)) }
        if cut.bottom > r.bottom { pieces.append(PdfRect(left, r.bottom, right, cut.bottom)) }
        return pieces
    }
}
