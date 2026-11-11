import Foundation

// Twin of windows/LazyPDF.Core/Annotations/AppearanceBuilder.Text.cs: free text boxes and stamps, the two kinds that
// draw text.

struct FontKey: Hashable {
    let family: String
    let style: Int
}

extension AppearanceBuilder {
    private static let textPadding = 2.0

    func freeText(_ a: PdfAnnotation) throws -> AppearanceCanvas {
        let c = canvas(a)
        let format = Self.freeTextFormat(a)
        let rd = a.rectDifference
        var box = rd.count == 4 ? PdfRect(a.rect.left + rd[0], a.rect.bottom + rd[1], a.rect.right - rd[2], a.rect.top - rd[3]) : a.rect
        if box.isEmpty { box = a.rect }
        let width = a.border.width
        c.transparency(a.opacity, multiply: false)

        if Self.paints(a.interiorColor) && c.color(a.interiorColor, stroke: false) {
            c.w.rect(c.x(box.left), c.y(box.bottom), box.width, box.height).fill()
        }
        let border = width > 0 && Self.paints(a.color) && c.color(a.color, stroke: true)
        if border {
            c.stroke(width, a.border.style == .dashed ? a.border.dash : nil)
            c.w.rect(c.x(box.left) + width / 2, c.y(box.bottom) + width / 2, box.width - width, box.height - width).stroke()
        }
        if a.callout.count >= 4 { Self.callout(c, a, border) }

        let paragraphs = Self.paragraphs(a, format)
        let inset = Self.textPadding + (border ? width : 0)
        let textBox = PdfRect(box.left + inset, box.bottom + inset, box.right - inset, box.top - inset)
        if textBox.isEmpty || paragraphs.isEmpty { return c }

        let runs = paragraphs.flatMap { $0 }
        var cache: [FontKey: PdfDrawFont] = [:]
        var names: [Int: String] = [:]
        // A font only has to cover the runs that are set in it.
        let lines = try TextLayout.layout(paragraphs, textBox.width, format) { f in
            try self.fontFor(f, runs.filter { $0.format.family == f.family && $0.format.style == f.style }.map { $0.text }, &cache)
        }

        c.w.save()
        c.w.rect(c.x(box.left), c.y(box.bottom), box.width, box.height).clip()
        var y = textBox.top
        for line in lines {
            if y < box.bottom { break }
            let baseline = y - line.ascent
            var x: Double
            switch a.alignment {
            case 1: x = textBox.left + (textBox.width - line.width) / 2
            case 2: x = textBox.right - line.width
            default: x = textBox.left
            }
            for piece in line.pieces {
                drawPiece(c, piece, x, baseline, &names)
                x += piece.width
            }
            y -= line.height
        }
        c.w.restore()
        return c
    }

    private func drawPiece(_ c: AppearanceCanvas, _ piece: Piece, _ x: Double, _ baseline: Double, _ names: inout [Int: String]) {
        if piece.text.isEmpty { return }
        let format = piece.run.format
        let name: String
        if let known = names[piece.font.reference.number] {
            name = known
        } else {
            name = c.addFont(piece.font.reference)
            names[piece.font.reference.number] = name
        }
        c.color(format.color, stroke: false)
        c.w.beginText().font(name, format.size).moveText(c.x(x), c.y(baseline)).show(piece.font.encode(piece.text)).endText()
        if format.underline {
            c.color(format.color, stroke: true)
            c.w.lineWidth(max(0.5, format.size / 18))
            c.move(x, baseline - format.size * 0.12).line(x + piece.width, baseline - format.size * 0.12)
            c.w.stroke()
        }
    }

    private static func callout(_ c: AppearanceCanvas, _ a: PdfAnnotation, _ hasColor: Bool) {
        let points = Self.points(a.callout)
        if points.count < 2 { return }
        if !hasColor { c.color(black, stroke: true) }
        let width = a.border.width > 0 ? a.border.width : 1
        c.stroke(width, nil)
        c.polyline(points, close: false)
        c.w.stroke()
        var line = a
        line.border.width = width
        line.color = hasColor ? a.color : black
        drawEnding(c, line, a.startEnding, points[0], unit(points[0].x - points[1].x, points[0].y - points[1].y))
    }

    private static func freeTextFormat(_ a: PdfAnnotation) -> TextFormat {
        var f = TextFormat.default
        let (font, size, color) = DefaultAppearance.parse(a.defaultAppearance)
        if let font { f = DefaultAppearance.formatOf(font, f) }
        if let size, size > 0 { f.size = size }
        if let color { f.color = color }
        return f.withCss(a.defaultStyle)
    }

    private static func paragraphs(_ a: PdfAnnotation, _ format: TextFormat) -> [[TextRun]] {
        if let rich = a.richText, !rich.isEmpty, let parsed = PdfRichText.parse(rich, format), parsed.contains(where: { !$0.isEmpty }) {
            return parsed
        }
        let text = a.contents ?? ""
        if text.isEmpty { return [] }
        return lines(of: text).map { $0.isEmpty ? [] : [TextRun($0, format)] }
    }

    // ReplaceLineEndings("\n").Split('\n'): CR, LF, CRLF, FF, NEL, LS and PS all end a line.
    private static func lines(of text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousReturn = false
        for c in text.unicodeScalars {
            if c == "\n" && previousReturn {
                previousReturn = false
                continue
            }
            previousReturn = c == "\r"
            switch c.value {
            case 0x0A, 0x0D, 0x0C, 0x85, 0x2028, 0x2029:
                lines.append(String(current))
                current = String.UnicodeScalarView()
            default:
                current.append(c)
            }
        }
        lines.append(String(current))
        return lines
    }

    private func fontFor(_ format: TextFormat, _ texts: [String], _ cache: inout [FontKey: PdfDrawFont]) throws -> PdfDrawFont {
        let key = FontKey(family: format.family, style: format.style.rawValue)
        if let known = cache[key] { return known }
        var font = try embedder.addCovering(format.family, format.style, texts)
        if font == nil { font = try embedder.add("Helvetica", format.style, texts) }
        guard let found = font else { throw InvalidOperationException(AnnotationText.noFont) }
        undrawn.formUnion(found.missing)
        cache[key] = found
        return found
    }

    func stamp(_ a: PdfAnnotation) throws -> AppearanceCanvas {
        let c = canvas(a)
        let name = a.iconName ?? "Draft"
        let label = AnnotationText.stampLabel(name)
        let color = a.color ?? Self.stampColor(name)
        c.transparency(a.opacity, multiply: false)
        let w = a.rect.width, h = a.rect.height
        let line = min(max(min(w, h) / 14, 1), 4)
        if c.color(color, stroke: true) {
            c.stroke(line, nil)
            let radius = min(h / 6, 6)
            Self.roundedRect(c, line / 2, line / 2, w - line / 2, h - line / 2, radius)
            c.w.stroke()
        }
        let bold = TextFormat("Helvetica", 12, true, false, false, color)
        var cache: [FontKey: PdfDrawFont] = [:]
        let font = try fontFor(bold, [label], &cache)
        let pad = line * 2
        let size = min(h * 0.5, (w - 2 * pad) / max(0.001, font.width(label, 1)))
        if size < 1 { return c }
        let textWidth = font.width(label, size)
        let baseline = (h - (font.ascent + font.descent) * size) / 2
        let fontName = c.addFont(font.reference)
        c.color(color, stroke: false)
        c.w.beginText().font(fontName, size).moveText((w - textWidth) / 2, baseline).show(font.encode(label)).endText()
        return c
    }

    private static func stampColor(_ name: String) -> [Double] {
        switch name {
        case "Approved", "Final", "ForPublicRelease": return [0, 0.5, 0.15]
        case "AsIs", "Experimental", "Sold", "Departmental", "ForComment": return [0, 0.2, 0.7]
        default: return [0.75, 0, 0]
        }
    }

    private static func roundedRect(_ c: AppearanceCanvas, _ l: Double, _ b: Double, _ r: Double, _ t: Double, _ radius: Double) {
        let kappa = 0.5522847498
        let k = radius * kappa
        c.w.moveTo(l + radius, b).lineTo(r - radius, b).curveTo(r - radius + k, b, r, b + radius - k, r, b + radius)
            .lineTo(r, t - radius).curveTo(r, t - radius + k, r - radius + k, t, r - radius, t)
            .lineTo(l + radius, t).curveTo(l + radius - k, t, l, t - radius + k, l, t - radius)
            .lineTo(l, b + radius).curveTo(l, b + radius - k, l + radius - k, b, l + radius, b).close()
    }
}
