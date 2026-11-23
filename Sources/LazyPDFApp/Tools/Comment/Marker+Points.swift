import Foundation
import LazyPDFKit

// Follows the points part of windows/LazyPDF.App/Tools/Comment/Marker.cs: the ends of a line and the corners of a polygon.

/// A point index that is out of range: a click that raced an undo, say. Never shown; the caller only refreshes.
public enum MarkError: Error {
    case badPoint
}

extension Marker {
    private static func userPoints(_ a: PdfAnnotation) -> [Double]? {
        switch a.type {
        case .line: return a.line.count >= 4 ? a.line : nil
        case .polyLine, .polygon: return a.vertices.count >= 4 ? a.vertices : nil
        default: return nil
        }
    }

    /// The ends of a line or the corners of a polygon in display space; nil for a mark that moves only by its box, and for a fixed one.
    public func pointsOf(_ a: PdfAnnotation) -> [ViewPoint]? {
        guard let xy = Self.userPoints(a), !Self.isFixed(a) else { return nil }
        let geometry = PageGeometry(document.pages[a.pageIndex])
        let count = a.type == .line ? 2 : xy.count / 2
        return (0..<count).map { i in
            let p = geometry.toDisplay(xy[2 * i], xy[2 * i + 1])
            return ViewPoint(p.x, p.y)
        }
    }

    /// Moves one end or corner; the box is fitted again to the points, the border and the heads.
    public func movePoint(_ a: PdfAnnotation, _ index: Int, _ to: ViewPoint) throws -> PdfAnnotation {
        guard let points = pointsOf(a), let old = Self.userPoints(a) else { throw ArgumentException("This mark has no points to move.") }
        guard index >= 0, index < points.count else { throw MarkError.badPoint }
        let p = PageGeometry(document.pages[a.pageIndex]).toUser(to.x, to.y)
        var xy = old
        xy[2 * index] = p.x
        xy[2 * index + 1] = p.y
        return try writePoints(a, xy)
    }

    // The annotation still holds the old points, and the box is made from the new ones.
    private func writePoints(_ a: PdfAnnotation, _ xy: [Double]) throws -> PdfAnnotation {
        try writer.edit(a, redraw: true) {
            a.dictionary[a.type == .line ? "L" : "Vertices"] = PdfArray(xy.map { PdfNumber($0) })
            var shifted = a
            if a.type == .line { shifted.line = xy } else { shifted.vertices = xy }
            fitBox(shifted, a.border.width, a.startEnding != .none || a.endEnding != .none)
        }
    }

    /// A mark with ends or corners to move.
    public static func hasPoints(_ a: PdfAnnotation) -> Bool { userPoints(a) != nil && !isFixed(a) }

    /// Corners can come and go on a polygon the app drew; a cloud keeps its corners and a line its two ends.
    public static func plainPolygon(_ a: PdfAnnotation) -> Bool {
        a.type == .polygon && a.cloud == 0 && !isFixed(a) && a.vertices.count >= 6
    }

    /// Adds a corner between corner `after` and the next one, the first when it is the last.
    public func insertPoint(_ a: PdfAnnotation, after: Int, at: ViewPoint) throws -> PdfAnnotation {
        guard Self.plainPolygon(a) else { throw ArgumentException("Corners cannot be added to this mark.") }
        guard after >= 0, after < a.vertices.count / 2 else { throw MarkError.badPoint }
        let p = PageGeometry(document.pages[a.pageIndex]).toUser(at.x, at.y)
        let cut = 2 * (after + 1)
        return try writePoints(a, Array(a.vertices[..<cut]) + [p.x, p.y] + Array(a.vertices[cut...]))
    }

    /// A polygon keeps three corners at least.
    public func canRemovePoint(_ a: PdfAnnotation, _ index: Int) -> Bool {
        Self.plainPolygon(a) && index >= 0 && index < a.vertices.count / 2 && a.vertices.count / 2 > 3
    }

    public func removePoint(_ a: PdfAnnotation, _ index: Int) throws -> PdfAnnotation {
        if Self.plainPolygon(a), index < 0 || index >= a.vertices.count / 2 { throw MarkError.badPoint }
        guard canRemovePoint(a, index) else { throw ArgumentException("A corner cannot be taken from this mark.") }
        let kept = a.vertices.enumerated().filter { $0.offset / 2 != index }.map { $0.element }
        return try writePoints(a, kept)
    }

    /// The corner that starts the side of a polygon nearest to the point, within the border and `tolerance` of it; -1 when no side is that near.
    public func segmentAt(_ a: PdfAnnotation, _ at: ViewPoint, tolerance: Double) -> Int {
        guard Self.plainPolygon(a) else { return -1 }
        let p = PageGeometry(document.pages[a.pageIndex]).toUser(at.x, at.y)
        let xy = a.vertices
        let n = xy.count / 2
        var best = -1
        var nearest = tolerance + a.border.width / 2
        for i in 0..<n {
            let j = (i + 1) % n
            let d = Self.distance(xy[2 * i], xy[2 * i + 1], xy[2 * j], xy[2 * j + 1], p.x, p.y)
            if d <= nearest {
                nearest = d
                best = i
            }
        }
        return best
    }
}
