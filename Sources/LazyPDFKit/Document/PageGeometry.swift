import Foundation

// Twin of windows/LazyPDF.Core/Document/PageGeometry.cs: converts between a page's user space (points, origin
// bottom-left) and the display points the app uses (origin top-left, y down) for the page as shown: the crop box,
// /Rotate (clockwise) and /UserUnit applied (ISO 32000-1 7.7.3.3, 14.11.2). Nothing else in the engine does this.

/// A rectangle in display points: origin top-left, y down.
public struct DisplayRect: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public final class PageGeometry {
    private let ma, mb, mc, md, me, mf: Double
    private let ia, ib, ic, id, ie, iff: Double

    public convenience init(_ page: PdfPage) {
        self.init(page.cropBox, page.rotate, page.userUnit)
    }

    /// `box` is the visible region in user space, `rotate` clockwise degrees (a multiple of 90) and `userUnit`
    /// the user space units per point (1 unless the page says otherwise).
    public init(_ box: PdfRect, _ rotate: Int, _ userUnit: Double = 1) {
        let u = userUnit > 0 ? userUnit : 1
        let rotation = ((rotate % 360) + 360) % 360 / 90 * 90
        self.rotation = rotation
        let turned = rotation == 90 || rotation == 270
        width = (turned ? box.height : box.width) * u
        height = (turned ? box.width : box.height) * u
        // display = (a x + c y + e, b x + d y + f)
        let m: (Double, Double, Double, Double, Double, Double)
        switch rotation {
        case 90: m = (0, u, u, 0, -box.bottom * u, -box.left * u)
        case 180: m = (-u, 0, 0, u, box.right * u, -box.bottom * u)
        case 270: m = (0, -u, -u, 0, box.top * u, box.right * u)
        default: m = (u, 0, 0, -u, -box.left * u, box.top * u)
        }
        (ma, mb, mc, md, me, mf) = m
        let det = m.0 * m.3 - m.1 * m.2
        ia = m.3 / det
        ib = -m.1 / det
        ic = -m.2 / det
        id = m.0 / det
        ie = (m.2 * m.5 - m.3 * m.4) / det
        iff = (m.1 * m.4 - m.0 * m.5) / det
    }

    /// The page as shown, in display points.
    public let width: Double
    public let height: Double

    /// The rotation applied: 0, 90, 180 or 270.
    public let rotation: Int

    /// The matrix [a b c d e f] taking user space to display points (x' = ax + cy + e, y' = bx + dy + f).
    public var matrix: (a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) { (ma, mb, mc, md, me, mf) }

    public func toDisplay(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        (ma * x + mc * y + me, mb * x + md * y + mf)
    }

    public func toUser(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        (ia * x + ic * y + ie, ib * x + id * y + iff)
    }

    /// The display rectangle that covers a user-space one.
    public func toDisplay(_ rect: PdfRect) -> DisplayRect {
        let p1 = toDisplay(rect.left, rect.bottom)
        let p2 = toDisplay(rect.right, rect.top)
        return DisplayRect(Swift.min(p1.x, p2.x), Swift.min(p1.y, p2.y), abs(p2.x - p1.x), abs(p2.y - p1.y))
    }

    /// The user-space rectangle that a display one covers.
    public func toUser(_ rect: DisplayRect) -> PdfRect {
        let p1 = toUser(rect.x, rect.y)
        let p2 = toUser(rect.x + rect.width, rect.y + rect.height)
        return PdfRect(p1.x, p1.y, p2.x, p2.y)
    }
}
