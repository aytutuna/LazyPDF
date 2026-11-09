import Foundation
import LazyPDFKit

// The second half of windows/LazyPDF.App/Tools/Comment/Marker.cs: which mark lies under a point, or under a stroke.

extension Marker {
    /// The topmost mark under a point of the page, if any.
    public func at(_ page: Int, _ point: ViewPoint, _ tolerance: Double) -> PdfAnnotation? {
        if page < 0 || page >= document.pages.count { return nil }
        let target = document.pages[page]
        let (x, y) = PageGeometry(target).toUser(point.x, point.y)
        let marks = PdfAnnotations.read(document, target)
        for mark in marks.reversed() where Self.selectable(mark) && Self.covers(mark, x, y, tolerance) {
            return mark
        }
        return nil
    }

    /// The marks that a stroke of the pointer crosses, also between the points it was sampled at.
    public func along(_ page: Int, _ path: [ViewPoint], _ tolerance: Double) -> [PdfAnnotation] {
        if page < 0 || page >= document.pages.count || path.isEmpty { return [] }
        let target = document.pages[page]
        let geometry = PageGeometry(target)
        let marks = PdfAnnotations.read(document, target).filter(Self.selectable)
        var hit: [Int: PdfAnnotation] = [:]
        var order: [Int] = []
        for point in Self.densify(path, tolerance) {
            let (x, y) = geometry.toUser(point.x, point.y)
            for mark in marks {
                guard let number = mark.reference?.number, hit[number] == nil, Self.covers(mark, x, y, tolerance) else { continue }
                hit[number] = mark
                order.append(number)
            }
        }
        return order.compactMap { hit[$0] }
    }

    private static func densify(_ path: [ViewPoint], _ step: Double) -> [ViewPoint] {
        var points = [path[0]]
        for i in 1..<max(path.count, 1) {
            let dx = path[i].x - path[i - 1].x, dy = path[i].y - path[i - 1].y
            let parts = max(1, Int(((dx * dx + dy * dy).squareRoot() / step).rounded(.up)))
            for k in 1...parts {
                points.append(ViewPoint(path[i - 1].x + dx * Double(k) / Double(parts), path[i - 1].y + dy * Double(k) / Double(parts)))
            }
        }
        return points
    }

    /// A mark the person may pick: not a reply or a hidden one, and not one the file locks.
    public static func selectable(_ a: PdfAnnotation) -> Bool {
        a.isMarkup && a.reference != nil && a.inReplyTo == nil && !a.flags.contains(.hidden)
            && !a.flags.contains(.locked) && !a.flags.contains(.readOnly)
    }

    private static func covers(_ a: PdfAnnotation, _ x: Double, _ y: Double, _ tolerance: Double) -> Bool {
        let reach = tolerance + a.border.width / 2
        let r = a.rect
        switch a.type {
        case .line where a.line.count >= 4:
            return near(a.line, closed: false, x, y, reach)
        case .polyLine where a.vertices.count >= 4:
            return near(a.vertices, closed: false, x, y, reach)
        case .polygon where a.vertices.count >= 4:
            return near(a.vertices, closed: true, x, y, reach)
        case .square where (a.interiorColor ?? []).isEmpty:
            return near([r.left, r.bottom, r.right, r.bottom, r.right, r.top, r.left, r.top], closed: true, x, y, reach)
        case .circle where (a.interiorColor ?? []).isEmpty:
            return onEllipse(r, x, y, reach)
        case .ink:
            return a.inkList.contains { near($0, closed: false, x, y, reach) }
        case .highlight, .underline, .strikeOut, .squiggly:
            if a.quads.isEmpty { return inside(r, x, y, tolerance) }
            return a.quads.contains { inside($0.bounds, x, y, tolerance) }
        default:
            return inside(r, x, y, tolerance)
        }
    }

    private static func inside(_ r: PdfRect, _ x: Double, _ y: Double, _ by: Double) -> Bool {
        x >= r.left - by && x <= r.right + by && y >= r.bottom - by && y <= r.top + by
    }

    private static func onEllipse(_ r: PdfRect, _ x: Double, _ y: Double, _ reach: Double) -> Bool {
        let rx = r.width / 2, ry = r.height / 2
        if rx <= 0 || ry <= 0 { return inside(r, x, y, reach) }
        let a = (x - r.left - rx) / rx, b = (y - r.bottom - ry) / ry
        let d = (a * a + b * b).squareRoot()
        return abs(d - 1) * min(rx, ry) <= reach
    }

    private static func near(_ xy: [Double], closed: Bool, _ x: Double, _ y: Double, _ reach: Double) -> Bool {
        let n = xy.count / 2
        if n == 0 { return false }
        if n == 1 { return distance(xy[0], xy[1], xy[0], xy[1], x, y) <= reach }
        for i in 0..<(closed ? n : n - 1) {
            let j = (i + 1) % n
            if distance(xy[2 * i], xy[2 * i + 1], xy[2 * j], xy[2 * j + 1], x, y) <= reach { return true }
        }
        return false
    }

    private static func distance(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ x: Double, _ y: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : min(max(((x - ax) * dx + (y - ay) * dy) / length, 0), 1)
        let ex = x - (ax + t * dx), ey = y - (ay + t * dy)
        return (ex * ex + ey * ey).squareRoot()
    }
}
