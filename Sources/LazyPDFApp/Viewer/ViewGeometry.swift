import Foundation

// The plain geometry the viewer's arithmetic runs on, shaped like the WPF Point, Size, Rect and Matrix it replaces from
// windows/LazyPDF.App/Viewer. No CoreGraphics, so it builds on Linux. Rectangles keep WPF's rules: touching counts as
// meeting, and a negative width is the empty rectangle.

public struct ViewPoint: Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = ViewPoint(0, 0)
}

public struct ViewSize: Equatable {
    public var width: Double
    public var height: Double

    public init(_ width: Double, _ height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = ViewSize(0, 0)
}

public struct ViewRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: ViewPoint, size: ViewSize) {
        self.init(origin.x, origin.y, size.width, size.height)
    }

    /// The smallest rectangle holding both points.
    public init(from a: ViewPoint, to b: ViewPoint) {
        let left = Swift.min(a.x, b.x), top = Swift.min(a.y, b.y)
        self.init(left, top, Swift.max(a.x, b.x) - left, Swift.max(a.y, b.y) - top)
    }

    public static let empty = ViewRect(.infinity, .infinity, -.infinity, -.infinity)

    public var isEmpty: Bool { width < 0 }
    public var left: Double { x }
    public var top: Double { y }
    public var right: Double { isEmpty ? -.infinity : x + width }
    public var bottom: Double { isEmpty ? -.infinity : y + height }
    public var size: ViewSize { ViewSize(width, height) }
    public var topLeft: ViewPoint { ViewPoint(x, y) }
    public var center: ViewPoint { ViewPoint(x + width / 2, y + height / 2) }

    public func contains(_ point: ViewPoint) -> Bool {
        !isEmpty && point.x >= x && point.x - width <= x && point.y >= y && point.y - height <= y
    }

    public func contains(_ other: ViewRect) -> Bool {
        !isEmpty && !other.isEmpty && x <= other.x && y <= other.y && right >= other.right && bottom >= other.bottom
    }

    public func intersectsWith(_ other: ViewRect) -> Bool {
        width >= 0 && other.width >= 0 && other.x <= right && other.right >= x && other.y <= bottom && other.bottom >= y
    }

    public static func intersect(_ a: ViewRect, _ b: ViewRect) -> ViewRect {
        guard a.intersectsWith(b) else { return .empty }
        let left = Swift.max(a.x, b.x), top = Swift.max(a.y, b.y)
        return ViewRect(left, top, Swift.max(Swift.min(a.right, b.right) - left, 0), Swift.max(Swift.min(a.bottom, b.bottom) - top, 0))
    }

    public func inflated(_ dx: Double, _ dy: Double) -> ViewRect {
        ViewRect(x - dx, y - dy, width + 2 * dx, height + 2 * dy)
    }
}

/// An affine map: x' = m11 x + m21 y + offsetX, y' = m12 x + m22 y + offsetY.
public struct ViewMatrix: Equatable {
    public var m11: Double
    public var m12: Double
    public var m21: Double
    public var m22: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(_ m11: Double, _ m12: Double, _ m21: Double, _ m22: Double, _ offsetX: Double, _ offsetY: Double) {
        self.m11 = m11
        self.m12 = m12
        self.m21 = m21
        self.m22 = m22
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    public func transform(_ p: ViewPoint) -> ViewPoint {
        ViewPoint(p.x * m11 + p.y * m21 + offsetX, p.x * m12 + p.y * m22 + offsetY)
    }

    /// The way back. A map that squashes the plane has none and gives the identity.
    public func inverted() -> ViewMatrix {
        let det = m11 * m22 - m12 * m21
        guard det != 0 else { return ViewMatrix(1, 0, 0, 1, 0, 0) }
        return ViewMatrix(m22 / det, -m12 / det, -m21 / det, m11 / det,
                          (m21 * offsetY - m22 * offsetX) / det, (m12 * offsetX - m11 * offsetY) / det)
    }

    /// Followed by a move of (`dx`, `dy`).
    public func translated(_ dx: Double, _ dy: Double) -> ViewMatrix {
        ViewMatrix(m11, m12, m21, m22, offsetX + dx, offsetY + dy)
    }
}
