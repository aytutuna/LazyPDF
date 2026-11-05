import Foundation

// Twin of windows/LazyPDF.Core/Annotations/AppearanceBuilder.Icons.cs: the note, caret, attachment and redaction marks.

extension AppearanceBuilder {
    // The system renderer draws its own icon for a note and ignores this one; other viewers use it.
    func note(_ a: PdfAnnotation) -> AppearanceCanvas {
        let c = canvas(a)
        let w = a.rect.width, h = a.rect.height
        c.transparency(a.opacity, multiply: false)
        c.color(a.color ?? Self.yellow, stroke: false)
        c.color(Self.black, stroke: true)
        c.w.lineWidth(max(0.5, min(w, h) / 24))
        if a.iconName == "Comment" {
            let m = 0.5
            c.w.moveTo(m, h * 0.3).lineTo(m, h - m).lineTo(w - m, h - m).lineTo(w - m, h * 0.3).lineTo(w * 0.55, h * 0.3)
                .lineTo(w * 0.25, m).lineTo(w * 0.3, h * 0.3).close().fillAndStroke()
            return c
        }
        c.w.rect(0.5, 0.5, w - 1, h - 1).fillAndStroke()
        for i in 0..<3 {
            let y = h * (0.72 - 0.2 * Double(i))
            c.w.moveTo(w * 0.2, y).lineTo(w * 0.8, y).stroke()
        }
        return c
    }

    func caret(_ a: PdfAnnotation) -> AppearanceCanvas {
        let c = canvas(a)
        let w = a.rect.width, h = a.rect.height
        c.transparency(a.opacity, multiply: false)
        if !c.color(a.color ?? Self.black, stroke: false) { return c }
        c.w.moveTo(0, 0).curveTo(w * 0.35, 0, w * 0.5, h * 0.4, w * 0.5, h).curveTo(w * 0.5, h * 0.4, w * 0.65, 0, w, 0).close().fill()
        return c
    }

    func attachment(_ a: PdfAnnotation) -> AppearanceCanvas {
        let c = canvas(a)
        let w = a.rect.width, h = a.rect.height
        c.transparency(a.opacity, multiply: false)
        c.color(a.color ?? [0.3, 0.3, 0.35], stroke: true)
        c.color(a.color ?? [0.3, 0.3, 0.35], stroke: false)
        c.w.lineWidth(max(0.75, min(w, h) / 10)).raw("1 J 1 j")
        switch a.iconName {
        case "Paperclip":
            c.w.moveTo(w * 0.35, h * 0.15).lineTo(w * 0.35, h * 0.85).lineTo(w * 0.7, h * 0.85).lineTo(w * 0.7, h * 0.25)
                .lineTo(w * 0.52, h * 0.25).lineTo(w * 0.52, h * 0.7).stroke()
        case "Graph":
            for i in 0..<3 { c.w.rect(w * (0.12 + 0.3 * Double(i)), h * 0.1, w * 0.22, h * (0.3 + 0.2 * Double(i))).fill() }
        case "Tag":
            c.w.moveTo(w * 0.1, h * 0.55).lineTo(w * 0.45, h * 0.9).lineTo(w * 0.9, h * 0.9).lineTo(w * 0.9, h * 0.45)
                .lineTo(w * 0.55, h * 0.1).close().fill()
        default:
            c.w.moveTo(w * 0.2, h * 0.2).lineTo(w * 0.5, h * 0.5).stroke()
            c.w.moveTo(w * 0.45, h * 0.35).lineTo(w * 0.65, h * 0.35).lineTo(w * 0.85, h * 0.55).lineTo(w * 0.85, h * 0.65)
                .lineTo(w * 0.35, h * 0.65).lineTo(w * 0.35, h * 0.55).close().fill()
        }
        return c
    }

    // Only the mark: an outline round the area to remove. The area itself is blanked by a later layer.
    func redact(_ a: PdfAnnotation) -> AppearanceCanvas {
        let c = canvas(a)
        c.transparency(a.opacity, multiply: false)
        if !c.color(a.color ?? Self.red, stroke: true) { return c }
        c.stroke(1.5, nil)
        let quads = a.quads
        if quads.isEmpty {
            c.w.rect(0.75, 0.75, a.rect.width - 1.5, a.rect.height - 1.5).stroke()
            return c
        }
        for q in quads {
            c.move(q.x1, q.y1).line(q.x2, q.y2).line(q.x4, q.y4).line(q.x3, q.y3)
            c.w.close().stroke()
        }
        return c
    }
}
