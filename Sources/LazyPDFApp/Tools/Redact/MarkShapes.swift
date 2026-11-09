import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Redact/MarkShapes.cs: takes marks between page space (what the viewer shows) and PDF user
// space (what the engine removes).

public enum MarkShapes {
    /// A mark over a box dragged between two points of page space. Its quad reads left to right as shown, on a turned page too.
    public static func box(_ page: Int, _ geometry: PageGeometry, from: ViewPoint, to: ViewPoint) -> RedactionMark {
        let (left, right) = (min(from.x, to.x), max(from.x, to.x))
        let (top, bottom) = (min(from.y, to.y), max(from.y, to.y))
        let a = geometry.toUser(left, bottom)
        let b = geometry.toUser(right, bottom)
        let c = geometry.toUser(right, top)
        let d = geometry.toUser(left, top)
        return RedactionMark(page, [TextQuad(a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y)])
    }

    public static func outline(_ geometry: PageGeometry, _ quad: TextQuad) -> [ViewPoint] {
        [(quad.x0, quad.y0), (quad.x1, quad.y1), (quad.x2, quad.y2), (quad.x3, quad.y3)].map {
            let at = geometry.toDisplay($0.0, $0.1)
            return ViewPoint(at.x, at.y)
        }
    }

    /// Where the mark starts, in page space, for the viewer to bring into view.
    public static func place(_ geometry: PageGeometry, _ mark: RedactionMark) -> ViewRect {
        let box = geometry.toDisplay(mark.quads[0].bounds)
        return ViewRect(box.x, box.y, box.width, box.height)
    }
}
