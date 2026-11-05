import Foundation

// Twin of windows/LazyPDF.Core/Stamps/StampCanvas.cs: content for one page drawn in the page as it is shown: y up, origin at
// the bottom-left of the crop box, rotation and /UserUnit already undone by one `cm`. Text drawn here is upright on a
// rotated page.

final class StampCanvas {
    private let id: Int
    private let inLayer: Bool

    /// The page as shown, in points.
    let width: Double
    let height: Double
    let writer = ContentWriter()

    init(_ page: PdfPage, _ id: Int, _ inLayer: Bool) {
        let geometry = PageGeometry(page)
        width = geometry.width
        height = geometry.height
        self.id = id
        self.inLayer = inLayer
        let o = geometry.toUser(0, 0)
        let x = geometry.toUser(1, 0)
        let y = geometry.toUser(0, 1)
        let flip = PdfMatrix(1, 0, 0, -1, 0, height)
        writer.save().concat(flip.multiply(PdfMatrix(x.x - o.x, x.y - o.y, y.x - o.x, y.y - o.y, o.x, o.y)))
    }

    /// Opens an artifact (ISO 32000-1 14.8.2.2) carrying the run's id, inside the optional content group if there is one.
    func beginArtifact(_ type: String, _ subtype: String?, _ bounds: PdfRect? = nil) {
        let properties = PdfDictionary()
        properties["Type"] = PdfName(type)
        if let subtype { properties["Subtype"] = PdfName(subtype) }
        if let bounds { properties["BBox"] = bounds.toArray() }
        properties[StampStreams.key] = PdfNumber(id)
        writer.op("BDC", [PdfName("Artifact"), properties])
        if inLayer { writer.op("BDC", [PdfName("OC"), PdfName(StampStreams.layerResourceName(id))]) }
    }

    func endArtifact() {
        if inLayer { writer.endMarked() }
        writer.endMarked()
    }

    func toArray() -> [UInt8] { writer.restore().toArray() }

    /// Rotation by `degrees` counter-clockwise about the centre of a box, as the matrix that takes the box's own space
    /// (origin bottom-left) to the page.
    static func place(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ degrees: Double) -> PdfMatrix {
        let a = degrees * Double.pi / 180
        let c = cos(a), s = sin(a)
        return PdfMatrix.translate(-width / 2, -height / 2)
            .multiply(PdfMatrix(c, s, -s, c, 0, 0))
            .multiply(PdfMatrix.translate(x + width / 2, y + height / 2))
    }
}
