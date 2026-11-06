import Foundation

// Twin of windows/LazyPDF.Core/Editing/PageEditor.Add.cs: new text boxes, pictures and shapes on a page.

/// How a new text box looks. `family` is asked of the editor's `FontSource`; Arial, Times New Roman and Courier New use
/// the Standard 14 fonts when the text fits. `size` is the font size in points as the page is shown, `lineSpacing`
/// multiplies the font's line height.
public struct TextBoxStyle {
    public var family: String
    public var style: FontStyles
    public var size: Double
    public var color: RgbColor
    public var alignment: TextAlignment
    public var lineSpacing: Double

    public init(family: String = "Helvetica", style: FontStyles = [], size: Double = 12, color: RgbColor = RgbColor(0, 0, 0),
                alignment: TextAlignment = .left, lineSpacing: Double = 1) {
        self.family = family
        self.style = style
        self.size = size
        self.color = color
        self.alignment = alignment
        self.lineSpacing = lineSpacing
    }
}

/// How a new line, rectangle or ellipse is painted; a nil colour is not painted.
public struct ShapeStyle {
    public var stroke: RgbColor?
    public var fill: RgbColor?
    public var width: Double
    public var opacity: Double

    public init(stroke: RgbColor? = nil, fill: RgbColor? = nil, width: Double = 1, opacity: Double = 1) {
        self.stroke = stroke
        self.fill = fill
        self.width = width
        self.opacity = opacity
    }
}

extension PageEditor {
    /// Adds text wrapped inside `box` (user space), upright on the page as it is shown. The top of the box is the top
    /// of the first line. When the lines are taller than the box the result says `overlaps`.
    public func addTextBox(_ box: PdfRect, _ text: String, _ style: TextBoxStyle? = nil) throws -> TextEditResult {
        let style = style ?? TextBoxStyle()
        if box.isEmpty || text.isEmpty { return .failed(EditingText.tooBig) }
        let model = try self.model
        let batch = EditBatch(model.document, model.page, model.scan)
        let embedder = PdfFontEmbedder(model.document, fonts)
        guard let draw = try embedder.add(style.family, style.style, [text]) else { return .failed(EditingText.noFont) }
        if !draw.missing.isEmpty {
            batch.discard()
            return .failed(EditingText.noGlyphs(lettersOf(draw.missing)))
        }

        let geometry = PageGeometry(model.page)
        let shown = geometry.toDisplay(box)
        let origin = geometry.toUser(0, 0)
        let across = geometry.toUser(1, 0)
        let up = geometry.toUser(0, -1)
        let (ax, ay) = (across.x - origin.x, across.y - origin.y)
        let (bx, by) = (up.x - origin.x, up.y - origin.y)
        let lines = draw.wrap(text, style.size, shown.width)
        let height = draw.lineHeight(style.size) * style.lineSpacing
        let name = batch.newName()
        let w = ContentWriter().save()
        w.fillRgb(Double(style.color.r) / 255.0, Double(style.color.g) / 255.0, Double(style.color.b) / 255.0)
        w.beginText().font(name, style.size)
        for i in 0..<lines.count {
            let width = draw.width(lines[i], style.size)
            let x: Double
            switch style.alignment {
            case .center: x = shown.x + (shown.width - width) / 2
            case .right: x = shown.x + shown.width - width
            default: x = shown.x
            }
            let y = shown.y + draw.ascent * style.size + Double(i) * height
            let (ux, uy) = geometry.toUser(x, y)
            let spaces = lines[i].unicodeScalars.filter { $0 == " " }.count
            let justify = style.alignment == .justify && !draw.isEmbedded && i < lines.count - 1 && spaces > 0
            if justify { w.wordSpacing((shown.width - width) / Double(spaces) / (ax * ax + ay * ay).squareRoot()) }
            w.textMatrix(PdfMatrix(ax, ay, bx, by, ux, uy))
            w.show(draw.encode(lines[i]))
            if justify { w.wordSpacing(0) }
        }
        w.endText().restore()
        batch.append(w.toArray(), [("Font", name, draw.reference)])
        let bottom = shown.y + draw.ascent * style.size + Double(lines.count - 1) * height - draw.descent * style.size
        var result = try finish("Add text", batch, TextBuilder(model.document, batch, fonts))
        result.overlaps = bottom > shown.y + shown.height + 0.01
        return result
    }

    /// Adds a picture inside `box` (user space), upright on the page as it is shown, centred and keeping its
    /// proportions. JPEG data is embedded as it is; other files go through the editor's `ImageCodec`.
    public func addImage(_ box: PdfRect, _ file: [UInt8]) throws -> ObjectEditResult {
        if box.isEmpty { return ObjectEditResult(0, [SkippedObject(id: -1, reason: EditingText.tooBig)]) }
        let model = try self.model
        guard let added = try ObjectEditor.addPicture(model.document, file, codec) else {
            return ObjectEditResult(0, [SkippedObject(id: -1, reason: EditingText.noImage)])
        }

        let geometry = PageGeometry(model.page)
        let shown = geometry.toDisplay(box)
        let scale = Swift.min(shown.width / Double(added.width), shown.height / Double(added.height))
        let w = Double(added.width) * scale, h = Double(added.height) * scale
        let x = shown.x + (shown.width - w) / 2, y = shown.y + (shown.height - h) / 2
        let origin = geometry.toUser(x, y + h)
        let across = geometry.toUser(x + w, y + h)
        let up = geometry.toUser(x, y)
        let matrix = PdfMatrix(across.x - origin.x, across.y - origin.y, up.x - origin.x, up.y - origin.y, origin.x, origin.y)

        let batch = EditBatch(model.document, model.page, model.scan)
        let name = batch.newName()
        let writer = ContentWriter().paint(name, matrix)
        batch.append(writer.toArray(), [("XObject", name, added.reference)])
        try batch.apply()
        try commit("Add picture")
        return ObjectEditResult(1, [])
    }

    /// Adds a straight line from one point to another (user space).
    public func addLine(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ style: ShapeStyle? = nil) throws -> ObjectEditResult {
        try addShape("Add line", style ?? ShapeStyle(stroke: RgbColor(0, 0, 0)), { w in w.moveTo(x1, y1).lineTo(x2, y2) }, true, false)
    }

    public func addRectangle(_ rect: PdfRect, _ style: ShapeStyle? = nil) throws -> ObjectEditResult {
        let style = style ?? ShapeStyle(stroke: RgbColor(0, 0, 0))
        return try addShape("Add rectangle", style, { w in w.rect(rect.left, rect.bottom, rect.width, rect.height) }, style.stroke != nil, style.fill != nil)
    }

    /// Adds an ellipse that fits the rectangle, drawn with four Bezier curves.
    public func addEllipse(_ rect: PdfRect, _ style: ShapeStyle? = nil) throws -> ObjectEditResult {
        let style = style ?? ShapeStyle(stroke: RgbColor(0, 0, 0))
        let k = 0.5522847498
        let cx = (rect.left + rect.right) / 2, cy = (rect.bottom + rect.top) / 2, rx = rect.width / 2, ry = rect.height / 2
        return try addShape("Add ellipse", style, { w in
            w.moveTo(cx + rx, cy)
                .curveTo(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry)
                .curveTo(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy)
                .curveTo(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry)
                .curveTo(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy)
                .close()
        }, style.stroke != nil, style.fill != nil)
    }

    private func addShape(_ label: String, _ style: ShapeStyle, _ path: (ContentWriter) -> Void, _ stroke: Bool, _ fill: Bool) throws -> ObjectEditResult {
        if !stroke && !fill { return ObjectEditResult(0, [SkippedObject(id: -1, reason: EditingText.nothingChanged)]) }
        let model = try self.model
        let batch = EditBatch(model.document, model.page, model.scan)
        let w = ContentWriter().save()
        var resources: [(category: String, name: String, value: PdfObject)] = []
        if style.opacity < 1 {
            let state = PdfDictionary()
            state["Type"] = PdfName("ExtGState")
            state["ca"] = PdfNumber(style.opacity)
            state["CA"] = PdfNumber(style.opacity)
            let name = batch.newName()
            resources.append(("ExtGState", name, state))
            w.graphicsState(name)
        }
        if let s = style.stroke { w.strokeRgb(Double(s.r) / 255.0, Double(s.g) / 255.0, Double(s.b) / 255.0) }
        if let f = style.fill { w.fillRgb(Double(f.r) / 255.0, Double(f.g) / 255.0, Double(f.b) / 255.0) }
        w.lineWidth(style.width)
        path(w)
        w.op(stroke && fill ? "B" : fill ? "f" : "S")
        w.restore()
        batch.append(w.toArray(), resources)
        try batch.apply()
        try commit(label)
        return ObjectEditResult(1, [])
    }
}
