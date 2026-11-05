import Foundation

// Twin of windows/LazyPDF.Core/Text/TextQuad.cs: four corners in page user space, bottom-left, bottom-right,
// top-right and top-left of a glyph box in the glyph's own frame, so rotated and skewed text keeps its slant.

public struct TextQuad: Equatable {
    public let x0: Double
    public let y0: Double
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double
    public let x3: Double
    public let y3: Double

    public init(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.x3 = x3
        self.y3 = y3
    }

    static let zero = TextQuad(0, 0, 0, 0, 0, 0, 0, 0)

    public var bounds: PdfRect {
        PdfRect(Swift.min(Swift.min(x0, x1), Swift.min(x2, x3)), Swift.min(Swift.min(y0, y1), Swift.min(y2, y3)),
                Swift.max(Swift.max(x0, x1), Swift.max(x2, x3)), Swift.max(Swift.max(y0, y1), Swift.max(y2, y3)))
    }

    public var center: (x: Double, y: Double) { ((x0 + x1 + x2 + x3) / 4, (y0 + y1 + y2 + y3) / 4) }

    /// The eight numbers of a /QuadPoints entry (ISO 32000-1 12.5.6.10): top-left, top-right, bottom-left, bottom-right.
    public func toQuadPoints() -> [Double] { [x3, y3, x2, y2, x0, y0, x1, y1] }

    public func contains(_ x: Double, _ y: Double) -> Bool {
        let a = Self.cross(x0, y0, x1, y1, x, y), b = Self.cross(x1, y1, x2, y2, x, y)
        let c = Self.cross(x2, y2, x3, y3, x, y), d = Self.cross(x3, y3, x0, y0, x, y)
        return (a >= 0 && b >= 0 && c >= 0 && d >= 0) || (a <= 0 && b <= 0 && c <= 0 && d <= 0)
    }

    /// Zero inside, else the distance to the nearest edge.
    public func distanceTo(_ x: Double, _ y: Double) -> Double {
        if contains(x, y) { return 0 }
        return Swift.min(Swift.min(Self.edge(x0, y0, x1, y1, x, y), Self.edge(x1, y1, x2, y2, x, y)),
                         Swift.min(Self.edge(x2, y2, x3, y3, x, y), Self.edge(x3, y3, x0, y0, x, y)))
    }

    private static func cross(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ px: Double, _ py: Double) -> Double {
        (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    }

    private static func edge(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ px: Double, _ py: Double) -> Double {
        let dx = bx - ax, dy = by - ay, length = dx * dx + dy * dy
        let t = length == 0 ? 0 : Swift.min(Swift.max(((px - ax) * dx + (py - ay) * dy) / length, 0), 1)
        let ex = px - (ax + t * dx), ey = py - (ay + t * dy)
        return (ex * ex + ey * ey).squareRoot()
    }
}

/// Grows a quad around quads in the frame of the first one added.
struct QuadBox {
    private var ux = 0.0, uy = 0.0, vx = 0.0, vy = 0.0
    private var umin = 0.0, umax = 0.0, vmin = 0.0, vmax = 0.0
    private var started = false

    var isEmpty: Bool { !started }

    mutating func add(_ q: TextQuad) {
        if !started {
            var dx = q.x1 - q.x0, dy = q.y1 - q.y0, length = (dx * dx + dy * dy).squareRoot()
            if length < 1e-9 {
                // A zero-width glyph: take the frame from its height.
                let hx = q.x3 - q.x0, hy = q.y3 - q.y0, height = (hx * hx + hy * hy).squareRoot()
                (dx, dy, length) = height < 1e-9 ? (1, 0, 1) : (hy, -hx, height)
            }
            ux = dx / length
            uy = dy / length
            vx = -uy
            vy = ux
            if (q.x3 - q.x0) * vx + (q.y3 - q.y0) * vy < 0 {
                vx = -vx
                vy = -vy
            }
            (umin, vmin) = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)
            (umax, vmax) = (-Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
            started = true
        }
        include(q.x0, q.y0)
        include(q.x1, q.y1)
        include(q.x2, q.y2)
        include(q.x3, q.y3)
    }

    private mutating func include(_ x: Double, _ y: Double) {
        let u = x * ux + y * uy, v = x * vx + y * vy
        umin = Swift.min(umin, u)
        umax = Swift.max(umax, u)
        vmin = Swift.min(vmin, v)
        vmax = Swift.max(vmax, v)
    }

    func toQuad() -> TextQuad {
        func p(_ u: Double, _ v: Double) -> (x: Double, y: Double) { (u * ux + v * vx, u * uy + v * vy) }
        let (a, b, c, d) = (p(umin, vmin), p(umax, vmin), p(umax, vmax), p(umin, vmax))
        return TextQuad(a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y)
    }
}
