import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfRect.cs: a rectangle in PDF user space (origin bottom-left, y up),
// never upside down: `left` is at most `right` and `bottom` at most `top`.

public struct PdfRect: Equatable {
    public let left: Double
    public let bottom: Double
    public let right: Double
    public let top: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        left = Swift.min(x1, x2)
        bottom = Swift.min(y1, y2)
        right = Swift.max(x1, x2)
        top = Swift.max(y1, y2)
    }

    public var width: Double { right - left }
    public var height: Double { top - bottom }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The part both rectangles cover; empty (and at `left`, `bottom` of this one) when they miss.
    public func intersect(_ other: PdfRect) -> PdfRect {
        let l = Swift.max(left, other.left), b = Swift.max(bottom, other.bottom)
        let r = Swift.min(right, other.right), t = Swift.min(top, other.top)
        return r > l && t > b ? PdfRect(l, b, r, t) : PdfRect(left, bottom, left, bottom)
    }

    /// [left bottom right top] as a PDF array.
    public func toArray() -> PdfArray {
        PdfArray([PdfNumber(left), PdfNumber(bottom), PdfNumber(right), PdfNumber(top)])
    }
}
