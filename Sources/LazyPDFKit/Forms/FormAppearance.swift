import Foundation

// Twin of windows/LazyPDF.Core/Forms/FormAppearance.cs: draws the /AP /N streams of widgets from the field's value, /DA, /Q
// and the widget's /MK. The system renderer ignores /NeedAppearances, so every value that changes goes through here.

/// What a widget's /MK, border and /DA say about how it is drawn (ISO 32000-1 12.5.5, 12.7.3.3, 12.5.6.19).
struct Look {
    var rectWidth: Double
    var rectHeight: Double
    var rotation: Int
    var background: [Double]?
    var borderColor: [Double]?
    var borderWidth: Double
    var style: BorderStyle
    var dash: [Double]
    var caption: String?
    var textColor: [Double]
    var fontSize: Double
    var fontName: String
    var alignment: Int

    /// The size of the space the appearance is drawn in: the rectangle turned by /MK /R.
    var width: Double { rotation % 180 == 0 ? rectWidth : rectHeight }
    var height: Double { rotation % 180 == 0 ? rectHeight : rectWidth }

    /// Where the border ends and the content may start: bevels and insets take twice the width.
    var inset: Double {
        if borderColor == nil { return 0 }
        return style == .beveled || style == .inset ? 2 * borderWidth : borderWidth
    }

    static func of(_ document: PdfDocument, _ field: FormField, _ widget: FormWidget) -> Look {
        let d = widget.dictionary
        let mk = document.dict(d, "MK")
        let border = PdfAnnotations.parse(document, d, nil)?.border ?? AnnotationBorder(1, .solid, [])
        let (font, size, color) = DefaultAppearance.parse(PdfText.read(document, d, "DA") ?? field.defaultAppearance)
        let rotation = ((document.integer(mk, "R") ?? 0) % 360 + 360) % 360 / 90 * 90
        let stroke = colorOf(document, mk?["BC"])
        return Look(rectWidth: widget.rect.width, rectHeight: widget.rect.height, rotation: rotation,
                    background: colorOf(document, mk?["BG"]), borderColor: stroke, borderWidth: stroke == nil ? 0 : border.width,
                    style: border.style, dash: border.dash, caption: PdfText.read(document, mk, "CA"), textColor: color ?? [0],
                    fontSize: size ?? 0, fontName: font ?? "Helv",
                    alignment: Int(Int32(truncatingIfNeeded: document.integer(d, "Q") ?? field.alignment)))
    }

    private static func colorOf(_ document: PdfDocument, _ value: PdfObject?) -> [Double]? {
        let numbers = PdfAnnotations.numbers(document, value)
        return numbers.count == 1 || numbers.count == 3 || numbers.count == 4 ? numbers : nil
    }
}

final class FormAppearance {
    let document: PdfDocument

    static let minAutoSize = 4.0
    static let maxAutoMultiline = 12.0
    static let maxSize = 200.0

    init(_ document: PdfDocument) {
        self.document = document
    }

    /// Replaces the widget's /AP. `display` is the text shown (formatted, for text and choice fields) and `font` the font it
    /// is set in; a check box or radio button needs no font; `onState` names the "on" state of a button that has none yet.
    /// Signature fields are left as they are.
    func apply(_ field: FormField, _ widget: FormWidget, _ font: FormFont?, _ display: String, _ color: [Double]? = nil, onState: String? = nil) throws {
        if widget.rect.isEmpty || field.kind == .signature { return }
        var look = Look.of(document, field, widget)
        if let color { look.textColor = color }
        switch field.kind {
        case .checkBox, .radio:
            try buttons(field, widget, look, onState)
        case .pushButton:
            if let mk = document.dict(widget.dictionary, "MK"), mk.containsKey("I") { return } // the icon is the artwork
            guard let font else { return }
            try setNormal(widget, pushButton(look, font))
        case .listBox:
            guard let font else { return }
            try setNormal(widget, listBox(field, look, font))
        default:
            guard let font else { return }
            try setNormal(widget, textField(field, look, font, display))
        }
    }

    // The rollover and down states of a button survive a redraw of the normal one.
    func setNormal(_ widget: FormWidget, _ normal: PdfObject) throws {
        let ap = document.dict(widget.dictionary, "AP")?.copy() ?? PdfDictionary()
        if let stream = normal as? PdfStream {
            ap["N"] = try document.add(stream)
        } else {
            ap["N"] = normal
        }
        widget.dictionary["AP"] = ap
    }

    func newCanvas(_ look: Look) -> AppearanceCanvas {
        AppearanceCanvas(document, PdfRect(0, 0, look.width, look.height))
    }

    // The form's BBox is the unrotated drawing space; /Matrix turns it into the widget's rectangle.
    func finish(_ canvas: AppearanceCanvas, _ look: Look) -> PdfStream {
        let stream = canvas.toStream()
        let w = look.rectWidth, h = look.rectHeight
        let m: [Double]
        switch look.rotation {
        case 90: m = [0, 1, -1, 0, w, 0]
        case 180: m = [-1, 0, 0, -1, w, h]
        case 270: m = [0, -1, 1, 0, 0, h]
        default: m = [1, 0, 0, 1, 0, 0]
        }
        stream.dictionary["Matrix"] = PdfArray(m.map { PdfNumber($0) })
        return stream
    }

    func frame(_ c: AppearanceCanvas, _ look: Look, ellipse: Bool) {
        let w = look.width, h = look.height, bw = look.borderWidth
        if let background = look.background, c.color(background, stroke: false) {
            if ellipse { c.ellipse(0, 0, w, h) } else { c.w.rect(0, 0, w, h) }
            c.w.fill()
        }
        guard let borderColor = look.borderColor, bw > 0, c.color(borderColor, stroke: true) else { return }
        if look.style == .underline {
            c.stroke(bw, nil)
            c.move(0, bw / 2).line(w, bw / 2)
            c.w.stroke()
            return
        }
        c.stroke(bw, look.style == .dashed ? (look.dash.isEmpty ? [3] : look.dash) : nil)
        if ellipse { c.ellipse(bw / 2, bw / 2, w - bw / 2, h - bw / 2) } else { c.w.rect(bw / 2, bw / 2, w - bw, h - bw) }
        c.w.stroke()
        if ellipse || (look.style != .beveled && look.style != .inset) { return }

        let raised = look.style == .beveled
        c.color(raised ? [1] : [0.5], stroke: false)
        c.polyline([(bw, bw), (bw, h - bw), (w - bw, h - bw), (w - 2 * bw, h - 2 * bw), (2 * bw, h - 2 * bw), (2 * bw, 2 * bw)], close: true)
        c.w.fill()
        c.color(raised ? [0.5] : [0.75], stroke: false)
        c.polyline([(w - bw, h - bw), (w - bw, bw), (bw, bw), (2 * bw, 2 * bw), (w - 2 * bw, 2 * bw), (w - 2 * bw, h - 2 * bw)], close: true)
        c.w.fill()
    }

    // Text goes in marked content /Tx and a clip of the field's interior, as Acrobat writes it.
    func showLines(_ c: AppearanceCanvas, _ look: Look, _ font: FormFont, _ size: Double, _ lines: [(text: String, x: Double, y: Double)]) {
        let name = c.addFont(font.reference)
        let inset = look.inset
        c.w.beginMarked("Tx").save()
        c.w.rect(inset, inset, max(0, look.width - 2 * inset), max(0, look.height - 2 * inset)).clip()
        c.color(look.textColor, stroke: false)
        c.w.beginText().font(name, size)
        for (text, x, y) in lines {
            let encoded = font.encode(text)
            if !encoded.isEmpty { c.w.textMatrix(PdfMatrix(1, 0, 0, 1, x, y)).show(encoded) }
        }
        c.w.endText().restore().endMarked()
    }

    static func bullets(_ font: FormFont, _ text: String) -> String {
        let mark = font.canShow("\u{2022}") ? "\u{2022}" : "*"
        return String(repeating: mark, count: text.unicodeScalars.count)
    }
}
