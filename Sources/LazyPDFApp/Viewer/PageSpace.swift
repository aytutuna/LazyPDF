import Foundation

// Port of windows/LazyPDF.App/Viewer/PageSpace.cs. Page space is the page as shown before the viewer rotates it: points
// (1/72 inch), origin at the top left of the crop box with /Rotate applied, y down. View space is device independent
// pixels in the viewer's element. A rotation is 0, 90, 180 or 270 degrees clockwise.

public enum PageSpace {
    /// Device independent pixels in one point at 100 %: the page shows at the size it prints.
    public static let dipPerPoint = 96.0 / 72.0

    /// The nearest multiple of 90 in 0 to 270.
    public static func normalizeRotation(_ degrees: Int) -> Int {
        let quarters = Int((Double(degrees) / 90).rounded(.toNearestOrEven))
        return ((quarters % 4 + 4) % 4) * 90
    }

    /// The size of a page of `page` points once rotated and scaled by `scale` (pixels per point).
    public static func shown(_ page: ViewSize, _ rotation: Int, _ scale: Double) -> ViewSize {
        rotation == 90 || rotation == 270
            ? ViewSize(page.height * scale, page.width * scale)
            : ViewSize(page.width * scale, page.height * scale)
    }

    /// Takes a point of the page to the plane the page is drawn in. `origin` is where the top left of the page as rotated
    /// lands; `scale` is pixels per point.
    public static func toView(_ page: ViewSize, _ rotation: Int, _ scale: Double, _ origin: ViewPoint) -> ViewMatrix {
        let k = scale
        switch rotation {
        case 90: return ViewMatrix(0, k, -k, 0, origin.x + page.height * k, origin.y)
        case 180: return ViewMatrix(-k, 0, 0, -k, origin.x + page.width * k, origin.y + page.height * k)
        case 270: return ViewMatrix(0, -k, k, 0, origin.x, origin.y + page.width * k)
        default: return ViewMatrix(k, 0, 0, k, origin.x, origin.y)
        }
    }

    /// The way back: a point of the plane to the page, whether or not it lies on the page.
    public static func toPage(_ toView: ViewMatrix) -> ViewMatrix {
        toView.inverted()
    }

    /// The smallest rectangle holding `rect` once `matrix` is applied.
    public static func transform(_ matrix: ViewMatrix, _ rect: ViewRect) -> ViewRect {
        ViewRect(from: matrix.transform(rect.topLeft), to: matrix.transform(ViewPoint(rect.right, rect.bottom)))
    }
}
