import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/GlyphOutline.cs: a glyph's outline in font units, y up.

public enum OutlineOp { case move, line, quad, cubic, close }

/// One step of a glyph outline in font units. (x, y) is where the step ends; (x1, y1) is the control
/// point of a quadratic curve or the first of a cubic one, (x2, y2) the second of a cubic one.
public struct OutlineSegment: Equatable {
    public var op: OutlineOp
    public var x: Double
    public var y: Double
    public var x1: Double
    public var y1: Double
    public var x2: Double
    public var y2: Double

    public init(_ op: OutlineOp, _ x: Double, _ y: Double, _ x1: Double = 0, _ y1: Double = 0, _ x2: Double = 0, _ y2: Double = 0) {
        self.op = op
        self.x = x
        self.y = y
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }
}

/// A glyph's outline in font units, y up. TrueType gives lines and quadratics, CFF and Type 1 lines and cubics.
public final class GlyphOutline {
    public private(set) var segments: [OutlineSegment] = []

    public init() {}

    public var isEmpty: Bool { segments.isEmpty }

    func add(_ segment: OutlineSegment) {
        segments.append(segment)
    }

    func moveTo(_ x: Double, _ y: Double) {
        segments.append(OutlineSegment(.move, x, y))
    }

    func lineTo(_ x: Double, _ y: Double) {
        segments.append(OutlineSegment(.line, x, y))
    }

    func quadTo(_ x1: Double, _ y1: Double, _ x: Double, _ y: Double) {
        segments.append(OutlineSegment(.quad, x, y, x1, y1))
    }

    func cubicTo(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double, _ y: Double) {
        segments.append(OutlineSegment(.cubic, x, y, x1, y1, x2, y2))
    }

    func close() {
        segments.append(OutlineSegment(.close, 0, 0))
    }

    /// The box around the points of the outline, control points included, or nil when it is empty.
    public func bounds() -> GlyphBounds? {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var any = false
        func grow(_ x: Double, _ y: Double) {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
        for s in segments {
            if s.op == .close { continue }
            any = true
            grow(s.x, s.y)
            if s.op == .quad || s.op == .cubic { grow(s.x1, s.y1) }
            if s.op == .cubic { grow(s.x2, s.y2) }
        }
        return any ? GlyphBounds(minX, minY, maxX, maxY) : nil
    }
}

public struct GlyphBounds: Equatable {
    public var xMin: Double
    public var yMin: Double
    public var xMax: Double
    public var yMax: Double

    public init(_ xMin: Double, _ yMin: Double, _ xMax: Double, _ yMax: Double) {
        self.xMin = xMin
        self.yMin = yMin
        self.xMax = xMax
        self.yMax = yMax
    }
}
