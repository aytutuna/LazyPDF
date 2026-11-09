import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Measure/MeasureShape.cs.

public enum MeasureKind: CaseIterable {
    case distance, perimeter, area

    public var title: String {
        switch self {
        case .distance: return L10n.t("Distance")
        case .perimeter: return L10n.t("Perimeter")
        case .area: return L10n.t("Area")
        }
    }
}

/// A finished measurement: points of one page in page space, not yet written to the file.
public struct MeasureItem: Equatable {
    public var kind: MeasureKind
    public var page: Int
    public var points: [ViewPoint]

    public init(_ kind: MeasureKind, _ page: Int, _ points: [ViewPoint]) {
        self.kind = kind
        self.page = page
        self.points = points
    }

    public var title: String { kind.title }

    public func value(_ scale: MeasureScale) -> String {
        kind == .area ? scale.area(MeasureShape.area(points)) : scale.length(MeasureShape.length(points, closed: kind == .perimeter))
    }

    public var middle: ViewPoint {
        if kind == .distance { return ViewPoint((points[0].x + points[points.count - 1].x) / 2, (points[0].y + points[points.count - 1].y) / 2) }
        let n = Double(points.count)
        return ViewPoint(points.reduce(0) { $0 + $1.x } / n, points.reduce(0) { $0 + $1.y } / n)
    }
}

public enum MeasureShape {
    public static func length(_ points: [ViewPoint], closed: Bool) -> Double {
        var sum = 0.0
        for i in 1..<max(points.count, 1) { sum += distance(points[i], points[i - 1]) }
        if closed && points.count > 2 { sum += distance(points[0], points[points.count - 1]) }
        return sum
    }

    public static func area(_ points: [ViewPoint]) -> Double {
        var twice = 0.0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            twice += a.x * b.y - b.x * a.y
        }
        return abs(twice) / 2
    }

    public static func nearest(_ candidates: [ViewPoint], _ at: ViewPoint, _ radius: Double) -> ViewPoint? {
        var best: ViewPoint?
        var near = radius
        for c in candidates {
            let d = distance(c, at)
            if d > near { continue }
            near = d
            best = c
        }
        return best
    }

    /// The place at the same distance from `from` along the nearest multiple of 45 degrees.
    public static func straighten(_ from: ViewPoint, _ to: ViewPoint) -> ViewPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let step = Double.pi / 4
        let angle = (atan2(dy, dx) / step).rounded(.toNearestOrEven) * step
        let length = (dx * dx + dy * dy).squareRoot()
        return ViewPoint(from.x + length * cos(angle), from.y + length * sin(angle))
    }

    static func distance(_ a: ViewPoint, _ b: ViewPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
