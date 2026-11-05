import Foundation

// Twin of windows/LazyPDF.Core/Annotations/AppearanceBuilder.Markup.cs: highlights, underlines, strikeouts and squiggly
// lines over the quads of a text markup.

extension AppearanceBuilder {
    // Highlights multiply with the page so the text under them stays black (12.5.6.10).
    func highlight(_ a: PdfAnnotation) -> AppearanceCanvas {
        let c = canvas(a)
        c.transparency(a.opacity, multiply: true)
        if !c.color(a.color ?? Self.yellow, stroke: false) { return c }
        let quads = a.quads
        for q in quads {
            c.move(q.x1, q.y1).line(q.x2, q.y2).line(q.x4, q.y4).line(q.x3, q.y3)
            c.w.close()
        }
        if !quads.isEmpty { c.w.fill() }
        return c
    }

    func underline(_ a: PdfAnnotation, strike: Bool) -> AppearanceCanvas {
        let c = canvas(a)
        c.transparency(a.opacity, multiply: false)
        if !c.color(a.color ?? Self.black, stroke: true) { return c }
        for q in a.quads {
            let height = ((q.x1 - q.x3) * (q.x1 - q.x3) + (q.y1 - q.y3) * (q.y1 - q.y3)).squareRoot()
            let width = min(max(height / 14, 0.75), 2)
            c.stroke(width, nil)
            if strike {
                c.move((q.x1 + q.x3) / 2, (q.y1 + q.y3) / 2).line((q.x2 + q.x4) / 2, (q.y2 + q.y4) / 2)
            } else {
                // Lifted by half the width so the stroke stays inside the quad.
                let (ux, uy) = Self.unit(q.x1 - q.x3, q.y1 - q.y3)
                c.move(q.x3 + ux * width / 2, q.y3 + uy * width / 2).line(q.x4 + ux * width / 2, q.y4 + uy * width / 2)
            }
            c.w.stroke()
        }
        return c
    }

    func squiggly(_ a: PdfAnnotation) -> AppearanceCanvas {
        let step = 2.0, maxSteps = 20_000.0
        let c = canvas(a)
        c.transparency(a.opacity, multiply: false)
        if !c.color(a.color ?? Self.black, stroke: true) { return c }
        c.stroke(0.75, nil)
        for q in a.quads {
            let length = ((q.x4 - q.x3) * (q.x4 - q.x3) + (q.y4 - q.y3) * (q.y4 - q.y3)).squareRoot()
            let (dx, dy) = Self.unit(q.x4 - q.x3, q.y4 - q.y3)
            let (ux, uy) = Self.unit(q.x1 - q.x3, q.y1 - q.y3)
            let steps = Int(saturating32: min(maxSteps, (length / step).rounded(.up)))
            for i in stride(from: 0, through: steps, by: 1) {
                let t = min(Double(i) * step, length), lift = i % 2 == 0 ? 0.4 : 1.8
                let x = q.x3 + dx * t + ux * lift, y = q.y3 + dy * t + uy * lift
                if i == 0 {
                    c.move(x, y)
                } else {
                    c.line(x, y)
                }
            }
            c.w.stroke()
        }
        return c
    }

    static func unit(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let length = (x * x + y * y).squareRoot()
        return length < 1e-9 ? (0, 1) : (x / length, y / length)
    }
}
