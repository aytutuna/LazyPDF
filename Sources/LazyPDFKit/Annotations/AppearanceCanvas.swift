import Foundation

// Twin of windows/LazyPDF.Core/Annotations/AppearanceCanvas.cs: the form XObject of an appearance stream being drawn.
// Callers give page coordinates; the form's own space starts at the annotation's lower left corner, so moving the
// annotation changes /Rect and nothing else (12.5.5).

final class AppearanceCanvas {
    private let document: PdfDocument
    private let resources = PdfDictionary()
    private var state: String?

    init(_ document: PdfDocument, _ rect: PdfRect) {
        self.document = document
        self.rect = rect
    }

    let rect: PdfRect
    let w = ContentWriter()

    func x(_ x: Double) -> Double { x - rect.left }
    func y(_ y: Double) -> Double { y - rect.bottom }

    @discardableResult
    func move(_ x: Double, _ y: Double) -> AppearanceCanvas {
        w.moveTo(self.x(x), self.y(y))
        return self
    }

    @discardableResult
    func line(_ x: Double, _ y: Double) -> AppearanceCanvas {
        w.lineTo(self.x(x), self.y(y))
        return self
    }

    @discardableResult
    func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) -> AppearanceCanvas {
        w.curveTo(x(x1), y(y1), x(x2), y(y2), x(x3), y(y3))
        return self
    }

    @discardableResult
    func polyline(_ points: [PdfPoint], close: Bool) -> AppearanceCanvas {
        for (i, point) in points.enumerated() {
            if i == 0 {
                move(point.x, point.y)
            } else {
                line(point.x, point.y)
            }
        }
        if close && !points.isEmpty { w.close() }
        return self
    }

    @discardableResult
    func ellipse(_ left: Double, _ bottom: Double, _ right: Double, _ top: Double) -> AppearanceCanvas {
        let kappa = 0.5522847498
        let cx = (left + right) / 2, cy = (bottom + top) / 2, rx = (right - left) / 2, ry = (top - bottom) / 2
        move(cx + rx, cy)
        curve(cx + rx, cy + ry * kappa, cx + rx * kappa, cy + ry, cx, cy + ry)
        curve(cx - rx * kappa, cy + ry, cx - rx, cy + ry * kappa, cx - rx, cy)
        curve(cx - rx, cy - ry * kappa, cx - rx * kappa, cy - ry, cx, cy - ry)
        curve(cx + rx * kappa, cy - ry, cx + rx, cy - ry * kappa, cx + rx, cy)
        w.close()
        return self
    }

    /// Sets the fill or stroke colour; false for an empty (transparent) colour, which paints nothing.
    @discardableResult
    func color(_ color: [Double]?, stroke: Bool) -> Bool {
        guard let color else { return false }
        switch color.count {
        case 1:
            if stroke { w.strokeGray(color[0]) } else { w.fillGray(color[0]) }
            return true
        case 3:
            if stroke { w.strokeRgb(color[0], color[1], color[2]) } else { w.fillRgb(color[0], color[1], color[2]) }
            return true
        case 4:
            if stroke { w.strokeCmyk(color[0], color[1], color[2], color[3]) } else { w.fillCmyk(color[0], color[1], color[2], color[3]) }
            return true
        default:
            return false
        }
    }

    @discardableResult
    func stroke(_ width: Double, _ dash: [Double]?) -> AppearanceCanvas {
        w.lineWidth(width)
        if let dash, !dash.isEmpty {
            w.op("d", [PdfArray(dash.map { PdfNumber($0) }), PdfNumber(0)])
        }
        return self
    }

    /// Opacity and blend mode through an /ExtGState of the form itself, because the system renderer ignores the
    /// annotation's /CA. Nothing is written for opaque, normal drawing.
    func transparency(_ opacity: Double, multiply: Bool) {
        if opacity >= 1 && !multiply { return }
        if state == nil {
            let graphicsState = PdfDictionary()
            graphicsState["Type"] = PdfName("ExtGState")
            graphicsState["CA"] = PdfNumber(opacity)
            graphicsState["ca"] = PdfNumber(opacity)
            graphicsState["BM"] = PdfName(multiply ? "Multiply" : "Normal")
            graphicsState["AIS"] = PdfBoolean(false)
            state = ContentResources.add(document, resources, "ExtGState", graphicsState, "GS")
        }
        if let state { w.graphicsState(state) }
    }

    func addFont(_ font: PdfReference) -> String { ContentResources.add(document, resources, "Font", font, "F") }

    func addXObject(_ xobject: PdfReference) -> String { ContentResources.add(document, resources, "XObject", xobject, "Im") }

    func toStream() -> PdfStream {
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("XObject")
        dictionary["Subtype"] = PdfName("Form")
        dictionary["FormType"] = PdfNumber(1)
        dictionary["BBox"] = PdfArray([PdfNumber(0), PdfNumber(0), PdfNumber(rect.width), PdfNumber(rect.height)])
        dictionary["Matrix"] = PdfArray([PdfNumber(1), PdfNumber(0), PdfNumber(0), PdfNumber(1), PdfNumber(0), PdfNumber(0)])
        dictionary["Resources"] = resources
        dictionary["Filter"] = PdfName("FlateDecode")
        return PdfStream(dictionary, data: PdfFilterEncoders.flate(w.toArray()))
    }
}
