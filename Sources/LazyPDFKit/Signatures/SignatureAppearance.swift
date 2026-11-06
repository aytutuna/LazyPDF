import Foundation

// Twin of windows/LazyPDF.Core/Signatures/SignatureAppearance.cs: the appearance of a visible signature: a form
// XObject with the picture or ink on the left, the text beside it.

enum SignatureAppearance {
    private static let margin = 3.0

    static func text(_ job: SignJob, _ look: SignatureLook) -> String {
        if let given = look.text { return given }
        let time = (try? job.request.time.toString("yyyy-MM-dd HH:mm zzz", .invariantCulture)) ?? ""
        var lines = ["\(SignatureText.signedBy) \(job.name)", "\(SignatureText.datePrefix) \(time)"]
        if let reason = job.reason, !reason.isEmpty { lines.append("\(SignatureText.reasonPrefix) \(reason)") }
        if let location = job.request.location, !location.isEmpty { lines.append("\(SignatureText.locationPrefix) \(location)") }
        return lines.joined(separator: "\n")
    }

    /// The font for the text, found before anything is added to the document; nil when there is no text.
    static func addFont(_ document: PdfDocument, _ job: SignJob, _ look: SignatureLook, _ text: String) throws -> PdfDrawFont? {
        if text.isEmpty { return nil }
        guard let font = try PdfFontEmbedder(document, job.request.fonts).add(look.fontFamily, .regular, [text]) else {
            throw InvalidOperationException(SignatureText.noFont)
        }
        return font
    }

    /// The appearance for a widget at `rect` on a page turned `rotate` degrees clockwise: it is drawn upright as the
    /// page is shown, and its /Matrix turns it back into the page's own space (12.5.5).
    static func draw(_ document: PdfDocument, _ rect: PdfRect, _ rotate: Int, _ look: SignatureLook, _ text: String, _ font: PdfDrawFont?) throws -> PdfReference {
        let sideways = rotate == 90 || rotate == 270
        let width = sideways ? rect.height : rect.width, height = sideways ? rect.width : rect.height
        let canvas = AppearanceCanvas(document, PdfRect(0, 0, width, height))
        let hasImage = look.jpeg != nil || look.image != nil
        let hasInk = !(look.ink ?? []).isEmpty
        let graphicsWidth = (hasImage || hasInk) ? (font == nil ? width : width * 0.4) : 0

        if hasImage {
            var image: PdfImage?
            if let jpeg = look.jpeg { image = try PdfImageWriter.addJpeg(document, jpeg) }
            if image == nil, let rgba = look.image { image = try PdfImageWriter.addRgba(document, rgba.width, rgba.height, rgba.rgba) }
            if let image {
                let scale = Swift.min((graphicsWidth - 2 * margin) / Double(image.width), (height - 2 * margin) / Double(image.height))
                let w = Double(image.width) * scale, h = Double(image.height) * scale
                let name = canvas.addXObject(image.reference)
                canvas.w.paint(name, PdfMatrix(w, 0, 0, h, (graphicsWidth - w) / 2, (height - h) / 2))
            }
        } else if hasInk, let ink = look.ink {
            let side = Swift.min(graphicsWidth, height) - 2 * margin
            let left = (graphicsWidth - side) / 2, bottom = (height - side) / 2
            canvas.w.save().strokeRgb(0, 0, 0.5).lineWidth(1.2).op("J", 1).op("j", 1)
            for stroke in ink {
                for (i, point) in stroke.enumerated() {
                    let x = left + Swift.min(Swift.max(point.x, 0), 1) * side, y = bottom + Swift.min(Swift.max(point.y, 0), 1) * side
                    if i == 0 { canvas.w.moveTo(x, y) } else { canvas.w.lineTo(x, y) }
                }
                if stroke.count == 1 { canvas.w.lineTo(left + stroke[0].x * side + 0.1, bottom + stroke[0].y * side) }
                canvas.w.stroke()
            }
            canvas.w.restore()
        }

        if let font { drawText(canvas, font, text, graphicsWidth + margin, width - graphicsWidth - 2 * margin, height - 2 * margin) }
        let form = canvas.toStream()
        if rotate != 0 { form.dictionary["Matrix"] = turn(rotate) }
        return try document.add(form)
    }

    private static func turn(_ degrees: Int) -> PdfArray {
        let (a, b) = degrees == 90 ? (0, 1) : degrees == 180 ? (-1, 0) : (0, -1)
        return PdfArray([PdfNumber(a), PdfNumber(b), PdfNumber(-b), PdfNumber(a), PdfNumber(0), PdfNumber(0)])
    }

    private static func drawText(_ canvas: AppearanceCanvas, _ font: PdfDrawFont, _ text: String, _ left: Double, _ width: Double, _ height: Double) {
        var size = 12.0
        var lines = font.wrap(text, size, width)
        while size > 4 && Double(lines.count) * font.lineHeight(size) > height {
            size -= 0.5
            lines = font.wrap(text, size, width)
        }
        let name = canvas.addFont(font.reference)
        let lineHeight = font.lineHeight(size)
        let top = margin + height - font.ascent * size
        canvas.w.beginText().font(name, size).fillGray(0).moveText(left, top)
        for (i, line) in lines.enumerated() {
            if i > 0 { canvas.w.moveText(0, -lineHeight) }
            canvas.w.show(font.encode(line))
        }
        canvas.w.endText()
    }
}
