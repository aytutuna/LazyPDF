import Foundation

// Twin of windows/LazyPDF.Core/Content/PdfMatrix.cs: a transformation matrix [a b c d e f] (ISO 32000-1 8.3.4):
// x' = ax + cy + e, y' = bx + dy + f. `multiply` applies this matrix first and the other second, the order the spec
// writes its products in.

public struct PdfMatrix: Equatable {
    public let a: Double
    public let b: Double
    public let c: Double
    public let d: Double
    public let e: Double
    public let f: Double

    public init(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        self.f = f
    }

    public static let identity = PdfMatrix(1, 0, 0, 1, 0, 0)

    public static func translate(_ x: Double, _ y: Double) -> PdfMatrix { PdfMatrix(1, 0, 0, 1, x, y) }

    public static func scale(_ x: Double, _ y: Double) -> PdfMatrix { PdfMatrix(x, 0, 0, y, 0, 0) }

    public var determinant: Double { a * d - b * c }

    /// The square root of the area scale, a fair single number for line widths and font sizes.
    public var scaleFactor: Double { abs(determinant).squareRoot() }

    public func multiply(_ m: PdfMatrix) -> PdfMatrix {
        PdfMatrix(
            a * m.a + b * m.c, a * m.b + b * m.d,
            c * m.a + d * m.c, c * m.b + d * m.d,
            e * m.a + f * m.c + m.e, e * m.b + f * m.d + m.f)
    }

    public func transform(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + e, b * x + d * y + f)
    }

    /// The box that covers the four transformed corners.
    public func transform(_ r: PdfRect) -> PdfRect {
        let p1 = transform(r.left, r.bottom)
        let p2 = transform(r.right, r.bottom)
        let p3 = transform(r.right, r.top)
        let p4 = transform(r.left, r.top)
        return PdfRect(
            nanMin(nanMin(p1.x, p2.x), nanMin(p3.x, p4.x)), nanMin(nanMin(p1.y, p2.y), nanMin(p3.y, p4.y)),
            nanMax(nanMax(p1.x, p2.x), nanMax(p3.x, p4.x)), nanMax(nanMax(p1.y, p2.y), nanMax(p3.y, p4.y)))
    }

    /// The inverse, or nil when the matrix flattens the plane.
    public func invert() -> PdfMatrix? {
        let det = determinant
        if det == 0 || !det.isFinite { return nil }
        return PdfMatrix(d / det, -b / det, -c / det, a / det, (c * f - d * e) / det, (b * e - a * f) / det)
    }

    /// The matrix an array of six numbers stands for; nil for anything else.
    public static func fromArray(_ array: PdfArray?, _ resolve: (PdfObject?) -> PdfObject?) -> PdfMatrix? {
        guard let array, array.items.count >= 6 else { return nil }
        var n: [Double] = []
        for i in 0..<6 {
            guard let number = resolve(array.items[i]) as? PdfNumber, number.value.isFinite else { return nil }
            n.append(number.value)
        }
        return PdfMatrix(n[0], n[1], n[2], n[3], n[4], n[5])
    }
}
