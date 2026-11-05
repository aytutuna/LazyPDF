import Foundation

// Twin of windows/LazyPDF.Core/Annotations/AppearanceBuilder.Endings.cs: the line endings of /LE (ISO 32000-1 12.5.6.7).

extension AppearanceBuilder {
    /// The size of a line ending for a stroke of `width`: the arrow head's length, the side of a square.
    static func endingSize(_ width: Double) -> Double { max(7, width * 4) }

    // dir is the unit vector pointing away from the line, out of the tip.
    static func drawEnding(_ c: AppearanceCanvas, _ a: PdfAnnotation, _ ending: LineEnding, _ tip: PdfPoint, _ dir: PdfPoint) {
        if ending == .none || a.border.width <= 0 { return }
        let size = endingSize(a.border.width)
        let fill = paints(a.interiorColor)
        let perp: PdfPoint = (-dir.y, dir.x)
        c.w.save()
        c.w.raw("[] 0 d")
        if fill { c.color(a.interiorColor, stroke: false) }
        switch ending {
        case .openArrow, .closedArrow, .rOpenArrow, .rClosedArrow:
            let sign = ending == .openArrow || ending == .closedArrow ? 1.0 : -1.0
            let out1 = rotate(dir.x * sign, dir.y * sign, Double.pi / 7)
            let out2 = rotate(dir.x * sign, dir.y * sign, -Double.pi / 7)
            c.move(tip.x - out1.x * size, tip.y - out1.y * size).line(tip.x, tip.y).line(tip.x - out2.x * size, tip.y - out2.y * size)
            let closed = ending == .closedArrow || ending == .rClosedArrow
            if closed { c.w.close() }
            paint(c, stroke: true, fill: closed && fill)
        case .butt:
            c.move(tip.x - perp.x * size / 2, tip.y - perp.y * size / 2).line(tip.x + perp.x * size / 2, tip.y + perp.y * size / 2)
            c.w.stroke()
        case .slash:
            let slash = rotate(perp.x, perp.y, Double.pi / 6)
            c.move(tip.x - slash.x * size / 2, tip.y - slash.y * size / 2).line(tip.x + slash.x * size / 2, tip.y + slash.y * size / 2)
            c.w.stroke()
        case .square:
            let h = size * 0.4
            c.move(tip.x - dir.x * h - perp.x * h, tip.y - dir.y * h - perp.y * h)
                .line(tip.x + dir.x * h - perp.x * h, tip.y + dir.y * h - perp.y * h)
                .line(tip.x + dir.x * h + perp.x * h, tip.y + dir.y * h + perp.y * h)
                .line(tip.x - dir.x * h + perp.x * h, tip.y - dir.y * h + perp.y * h)
            c.w.close()
            paint(c, stroke: true, fill: fill)
        case .diamond:
            let h = size * 0.5
            c.move(tip.x + dir.x * h, tip.y + dir.y * h).line(tip.x + perp.x * h, tip.y + perp.y * h)
                .line(tip.x - dir.x * h, tip.y - dir.y * h).line(tip.x - perp.x * h, tip.y - perp.y * h)
            c.w.close()
            paint(c, stroke: true, fill: fill)
        case .circle:
            c.ellipse(tip.x - size * 0.4, tip.y - size * 0.4, tip.x + size * 0.4, tip.y + size * 0.4)
            paint(c, stroke: true, fill: fill)
        case .none:
            break
        }
        c.w.restore()
    }

    private static func rotate(_ x: Double, _ y: Double, _ angle: Double) -> PdfPoint {
        (x * cos(angle) - y * sin(angle), x * sin(angle) + y * cos(angle))
    }
}
