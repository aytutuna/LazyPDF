import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionOverlay.cs: what goes on a page in place of what was removed: the fill, and
// the overlay text.

enum RedactionOverlay {
    private static let minSize = 3.0
    private static let maxSize = 16.0

    static func fillOf(_ mark: RedactionMark, _ options: RedactionOptions) -> [Double] {
        if let fill = mark.fill, [1, 3, 4].contains(fill.count) { return fill }
        if let fill = options.fill, [1, 3, 4].contains(fill.count) { return fill }
        return [0]
    }

    static func build(_ marks: [RedactionMark], _ options: RedactionOptions, _ font: PdfDrawFont?, _ fontName: String) -> [UInt8] {
        let w = ContentWriter().save()
        for mark in marks {
            let fill = fillOf(mark, options)
            color(w, fill)
            for q in mark.quads { w.raw(RedactionPaths.polygons([MarkArea.of(q).points]) + "f") }
            guard let text = mark.overlayText ?? options.overlayText, let font, !text.isEmpty else { continue }
            for q in mark.quads { self.text(w, q, text, options.repeatOverlay, font, fontName, dark(fill)) }
        }
        return w.restore().toArray()
    }

    private static func color(_ w: ContentWriter, _ color: [Double]) {
        switch color.count {
        case 1: w.fillGray(color[0])
        case 3: w.fillRgb(color[0], color[1], color[2])
        default: w.fillCmyk(color[0], color[1], color[2], color[3])
        }
    }

    private static func dark(_ c: [Double]) -> Bool {
        switch c.count {
        case 1: return c[0] < 0.5
        case 3: return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2] < 0.5
        default: return 1 - nanMin(1, 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2] + c[3]) < 0.5
        }
    }

    private static func text(_ w: ContentWriter, _ q: TextQuad, _ text: String, _ repeating: Bool, _ font: PdfDrawFont, _ fontName: String, _ onDark: Bool) {
        let width = (pow(q.x1 - q.x0, 2) + pow(q.y1 - q.y0, 2)).squareRoot()
        let height = (pow(q.x3 - q.x0, 2) + pow(q.y3 - q.y0, 2)).squareRoot()
        if width < 1 || height < 1 { return }
        var size = PdfFunction.clamp(height * 0.6, 1, maxSize)
        let natural = font.width(text, size)
        if natural > width * 0.98 { size *= width * 0.98 / natural }
        if size < minSize { return }
        var line = text
        if repeating {
            let times = Int(saturating32: width * 0.98 / font.width(text + " ", size))
            if times > 1 { line = Array(repeating: text, count: times).joined(separator: " ") }
        }
        let drawn = font.width(line, size)
        let ux = (q.x1 - q.x0) / width, uy = (q.y1 - q.y0) / width
        let dx = (width - drawn) / 2, dy = height / 2 - size * (font.ascent + font.descent) / 2
        w.beginText().font(fontName, size)
        if onDark { w.fillGray(1) } else { w.fillGray(0) }
        w.textMatrix(PdfMatrix(ux, uy, -uy, ux, q.x0 + dx * ux - dy * uy, q.y0 + dx * uy + dy * ux)).show(font.encode(line)).endText()
    }
}
