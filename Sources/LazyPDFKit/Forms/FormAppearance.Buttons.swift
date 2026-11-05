import Foundation

// Twin of windows/LazyPDF.Core/Forms/FormAppearance.Buttons.cs: the appearance of check boxes, radio buttons and push
// buttons.

extension FormAppearance {
    // The marks of /MK /CA for check boxes and radio buttons are ZapfDingbats characters; the six Acrobat offers are drawn
    // as paths so that no font is needed.
    private static let check: UInt16 = 0x34, circle: UInt16 = 0x6C, cross: UInt16 = 0x38
    private static let diamond: UInt16 = 0x75, square: UInt16 = 0x6E, star: UInt16 = 0x48

    func buttons(_ field: FormField, _ widget: FormWidget, _ look: Look, _ onState: String?) throws {
        let on = widget.onState ?? onState ?? "Yes"
        var mark = field.kind == .radio ? Self.circle : Self.check
        if let first = look.caption?.utf16.first { mark = first }
        let round = field.kind == .radio && mark == Self.circle
        let states = PdfDictionary()
        states[on] = try document.add(buttonState(look, mark, round, isOn: true))
        states["Off"] = try document.add(buttonState(look, mark, round, isOn: false))
        try setNormal(widget, states)
    }

    private func buttonState(_ look: Look, _ mark: UInt16, _ round: Bool, isOn: Bool) throws -> PdfStream {
        let c = newCanvas(look)
        frame(c, look, ellipse: round)
        if isOn { try drawMark(c, look, mark) }
        return finish(c, look)
    }

    private func drawMark(_ c: AppearanceCanvas, _ look: Look, _ mark: UInt16) throws {
        let available = max(1, min(look.width, look.height) - 2 * (look.inset + 1))
        let s = look.fontSize > 0 ? min(look.fontSize, available) : available
        let cx = look.width / 2, cy = look.height / 2
        c.w.beginMarked("Tx").save()
        c.color(look.textColor, stroke: false)
        c.color(look.textColor, stroke: true)
        switch mark {
        case Self.check:
            c.w.op("J", 1).op("j", 1).lineWidth(0.14 * s)
            c.move(cx - 0.30 * s, cy - 0.02 * s).line(cx - 0.08 * s, cy - 0.26 * s).line(cx + 0.32 * s, cy + 0.30 * s)
            c.w.stroke()
        case Self.cross:
            c.w.op("J", 1).lineWidth(0.14 * s)
            c.move(cx - 0.28 * s, cy - 0.28 * s).line(cx + 0.28 * s, cy + 0.28 * s)
            c.move(cx - 0.28 * s, cy + 0.28 * s).line(cx + 0.28 * s, cy - 0.28 * s)
            c.w.stroke()
        case Self.circle:
            c.ellipse(cx - 0.3 * s, cy - 0.3 * s, cx + 0.3 * s, cy + 0.3 * s)
            c.w.fill()
        case Self.diamond:
            c.polyline([(cx, cy + 0.38 * s), (cx + 0.38 * s, cy), (cx, cy - 0.38 * s), (cx - 0.38 * s, cy)], close: true)
            c.w.fill()
        case Self.square:
            c.w.rect(cx - 0.28 * s, cy - 0.28 * s, 0.56 * s, 0.56 * s).fill()
        case Self.star:
            var points: [PdfPoint] = []
            for i in 0..<10 {
                let r = (i % 2 == 0 ? 0.44 : 0.18) * s, angle = Double.pi / 2 + Double(i) * Double.pi / 5
                points.append((cx + r * cos(angle), cy + r * sin(angle) - 0.02 * s))
            }
            c.polyline(points, close: true)
            c.w.fill()
        default:
            try dingbat(c, mark, s, cx, cy)
        }
        c.w.restore().endMarked()
    }

    private func dingbat(_ c: AppearanceCanvas, _ mark: UInt16, _ size: Double, _ cx: Double, _ cy: Double) throws {
        guard let zapf = Standard14.find("ZapfDingbats") else { return }
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("Font")
        dictionary["Subtype"] = PdfName("Type1")
        dictionary["BaseFont"] = PdfName(zapf.name)
        let font = try document.add(dictionary)
        let encoding = zapf.builtInEncoding
        var width = 800.0
        let index = Int(mark & 0xFF)
        if index < encoding.count, let glyph = encoding[index], let known = zapf.widthOf(glyph) { width = Double(known) }
        c.w.beginText().font(c.addFont(font), size).textMatrix(PdfMatrix(1, 0, 0, 1, cx - width * size / 2000, cy - 0.35 * size))
            .show([UInt8(truncatingIfNeeded: mark)]).endText()
    }

    func pushButton(_ look: Look, _ font: FormFont) -> PdfStream {
        let c = newCanvas(look)
        frame(c, look, ellipse: false)
        guard let caption = look.caption, !caption.isEmpty else { return finish(c, look) }

        let pad = look.inset + 1
        var size = look.fontSize
        if size <= 0 {
            size = min(Self.maxSize, max(Self.minAutoSize, (look.height - 2 * look.inset - 2) / (font.ascent - font.descent)))
            let width = font.width(caption, size)
            if width > look.width - 2 * pad { size = max(Self.minAutoSize, size * (look.width - 2 * pad) / width) }
        }
        let baseline = (look.height - font.lineHeight(size)) / 2 - font.descent * size
        showLines(c, look, font, size, [(caption, (look.width - font.width(caption, size)) / 2, baseline)])
        return finish(c, look)
    }
}
