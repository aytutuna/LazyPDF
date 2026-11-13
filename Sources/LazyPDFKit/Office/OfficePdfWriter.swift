import Foundation

// Twin of windows/LazyPDF.Core/Office/Layout/OfficePdfWriter.cs: lays a document out and writes it as a PDF with
// embedded subset fonts, so the text stays selectable.

enum OfficePdfWriter {
    /// Pixels of all pictures in one document that are read; later pictures are skipped.
    static let maxPicturePixels = 1 << 27

    private struct FontKey: Hashable {
        let family: String
        let style: Int
    }

    /// When `contents` is given, it receives the content stream of every page as written. `images` reads pictures that are not
    /// JPEG; without it only JPEG pictures are drawn. Throws
    /// `InvalidOperationException` (the message is `ExportText.noFont`) when no font can draw the text, and
    /// `PdfReadException` when the page size or margins leave no room or the document runs past `Paginator.maxPages`.
    static func create(_ document: LayoutDocument, _ fonts: FontSource?, contents: ((Int, [UInt8]) -> Void)? = nil, images: ImageCodec? = nil) throws -> OfficePdf {
        try create(try Paginator(document, LayoutFonts(fonts)).run(), fonts, contents: contents, images: images)
    }

    /// Writes pages that are already laid out.
    static func create(_ layout: LayoutResult, _ fonts: FontSource?, contents: ((Int, [UInt8]) -> Void)? = nil, images: ImageCodec? = nil) throws -> OfficePdf {
        let pdf = try ExportPdf.newDocument()
        let embedder = PdfFontEmbedder(pdf, fonts, (fonts as? OfficeFontSource)?.shaper)

        var order: [FontKey] = []
        var texts: [FontKey: [String]] = [:]
        for page in layout.pages {
            for case .text(let box) in page.boxes {
                let key = FontKey(family: box.family, style: box.style.rawValue)
                if texts[key] == nil {
                    texts[key] = []
                    order.append(key)
                }
                // A mark in front makes the embedder collect the glyphs of the text as a right-to-left run, brackets mirrored.
                texts[key]!.append(box.rightToLeft ? "\u{200F}" + box.text : box.text)
            }
        }
        var pictures: [ObjectIdentifier: PdfImage?] = [:]
        var unreadable = 0
        var pixels = 0
        for page in layout.pages {
            for case .image(let box) in page.boxes {
                try Task.checkCancellation()
                let id = ObjectIdentifier(box.source.file)
                if pictures[id] == nil {
                    // Pictures come from an untrusted document: past the budget the rest are counted as unreadable, undecoded.
                    var image: PdfImage?
                    if pixels <= maxPicturePixels { image = try PdfImageWriter.addPicture(pdf, box.source.file.bytes, images) }
                    if let image { pixels += image.width * image.height }
                    pictures[id] = .some(image)
                }
                if pictures[id]! == nil { unreadable += 1 }
            }
        }
        var drawn: [FontKey: PdfDrawFont] = [:]
        for key in order {
            guard let font = try embedder.add(key.family, FontStyles(rawValue: key.style), texts[key]!, embed: true) else {
                throw InvalidOperationException(ExportText.noFont)
            }
            drawn[key] = font
        }

        var i = 0
        while i < layout.pages.count {
            var run = 1
            while i + run < layout.pages.count && layout.pages[i + run].width == layout.pages[i].width && layout.pages[i + run].height == layout.pages[i].height { run += 1 }
            try PageOperations.insertBlank(pdf, i, layout.pages[i].width, layout.pages[i].height, run)
            i += run
        }
        for i in 0..<layout.pages.count {
            try Task.checkCancellation()
            let content = try Self.content(pdf, pdf.pages[i], layout.pages[i], drawn, pictures)
            contents?(i, content)
            let dictionary = PdfDictionary()
            dictionary["Filter"] = PdfName("FlateDecode")
            pdf.pages[i].dictionary["Contents"] = try pdf.add(PdfStream(dictionary, data: PdfFilterEncoders.flate(content)))
        }
        var skipped = layout.skipped
        if unreadable > 0 { skipped.append(SkippedFeature(SkippedKinds.unreadablePicture, unreadable)) }
        return OfficePdf(try pdf.saveRewrite(), layout.pages.count, skipped, layout.missing)
    }

    // Everything is rounded to 1/100 point, so that both engines write the same numbers.
    private static func round2(_ value: Double) -> Double { (value * 100).rounded(.toNearestOrAwayFromZero) / 100 + 0.0 }

    private static func channel(_ value: Int) -> Double { (Double(value) / 255.0 * 1000).rounded(.toNearestOrAwayFromZero) / 1000 }

    private static func content(_ pdf: PdfDocument, _ page: PdfPage, _ layout: LayoutPage, _ fonts: [FontKey: PdfDrawFont], _ pictures: [ObjectIdentifier: PdfImage?]) throws -> [UInt8] {
        let writer = ContentWriter()
        var names: [FontKey: String] = [:]
        var imageNames: [ObjectIdentifier: String] = [:]
        let resources = ContentResources.forEdit(pdf, page)
        var color = -1
        func setColor(_ rgb: Int) {
            if rgb == color { return }
            color = rgb
            writer.fillRgb(channel(rgb >> 16 & 0xFF), channel(rgb >> 8 & 0xFF), channel(rgb & 0xFF))
        }

        for box in layout.boxes {
            switch box {
            case .rect(let rect):
                setColor(rect.color)
                writer.rect(round2(rect.x), round2(layout.height - rect.y - rect.height), round2(rect.width), round2(rect.height)).fill()
            case .image(let picture):
                let id = ObjectIdentifier(picture.source.file)
                guard let found = pictures[id], let image = found else { continue }
                if imageNames[id] == nil { imageNames[id] = ContentResources.add(pdf, resources, "XObject", image.reference, "Im") }
                draw(writer, imageNames[id]!, picture, layout.height)
            case .path(let path):
                outline(writer, path, layout.height)
            case .text(let text):
                let key = FontKey(family: text.family, style: text.style.rawValue)
                let font = fonts[key]!
                if names[key] == nil { names[key] = ContentResources.add(pdf, resources, "Font", font.reference, "F") }
                setColor(text.color)
                writer.beginText().font(names[key]!, round2(text.size)).moveText(round2(text.x), round2(layout.height - text.baseline))
                if text.spaceExtra > 0 { justified(writer, font, text) }
                else if text.rightToLeft { writer.showRun(font, text.text, true, round2(text.size)) }
                else { writer.show(font.encode(text.text)) }
                writer.endText()
            }
        }
        return writer.toArray()
    }

    private static func outline(_ writer: ContentWriter, _ path: PlacedPath, _ pageHeight: Double) {
        writer.save()
        if let fill = path.fill { writer.fillRgb(channel(fill >> 16 & 0xFF), channel(fill >> 8 & 0xFF), channel(fill & 0xFF)) }
        if let stroke = path.stroke {
            writer.strokeRgb(channel(stroke.color >> 16 & 0xFF), channel(stroke.color >> 8 & 0xFF), channel(stroke.color & 0xFF)).lineWidth(round2(stroke.width))
            if !stroke.dash.isEmpty { writer.op("d", [PdfArray(stroke.dash.map { PdfNumber(round2($0)) }), PdfNumber(0)]) }
        }
        for c in path.commands {
            switch c {
            case .move(let x, let y): writer.moveTo(round2(x), round2(pageHeight - y))
            case .line(let x, let y): writer.lineTo(round2(x), round2(pageHeight - y))
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                writer.curveTo(round2(x1), round2(pageHeight - y1), round2(x2), round2(pageHeight - y2), round2(x), round2(pageHeight - y))
            case .close: writer.close()
            }
        }
        if path.fill != nil && path.stroke != nil { writer.fillAndStroke() }
        else if path.fill != nil { writer.fill() }
        else if path.stroke != nil { writer.stroke() }
        else { writer.endPath() }
        writer.restore()
    }

    private static func draw(_ writer: ContentWriter, _ name: String, _ box: PlacedImage, _ pageHeight: Double) {
        if box.rotation == 0 && !box.flipH {
            drawUpright(writer, name, box, pageHeight)
            return
        }
        // Mirror about the center, then turn; the page runs up, so a clockwise turn is a negative angle.
        let cx = box.x + box.width / 2, cy = pageHeight - box.y - box.height / 2
        let angle = -box.rotation * Double.pi / 180, cos = Foundation.cos(angle), sin = Foundation.sin(angle)
        let fx = box.flipH ? -1.0 : 1.0
        let turn = PdfMatrix(round4(cos * fx), round4(sin * fx), round4(-sin), round4(cos), round2(cx - cos * fx * cx + sin * cy), round2(cy - sin * fx * cx - cos * cy))
        writer.save().concat(turn)
        drawUpright(writer, name, box, pageHeight)
        writer.restore()
    }

    private static func round4(_ value: Double) -> Double { (value * 10000).rounded(.toNearestOrAwayFromZero) / 10000 + 0.0 }

    // A cropped picture is drawn at the size the whole picture would have and clipped to the visible part.
    private static func drawUpright(_ writer: ContentWriter, _ name: String, _ box: PlacedImage, _ pageHeight: Double) {
        let s = box.source
        let visibleX = 1 - s.cropLeft - s.cropRight, visibleY = 1 - s.cropTop - s.cropBottom
        let bottom = pageHeight - box.y - box.height
        if s.cropLeft + s.cropTop + s.cropRight + s.cropBottom == 0 || visibleX < 0.05 || visibleY < 0.05 {
            writer.paint(name, PdfMatrix(round2(box.width), 0, 0, round2(box.height), round2(box.x), round2(bottom)))
            return
        }
        let width = box.width / visibleX, height = box.height / visibleY
        writer.save().rect(round2(box.x), round2(bottom), round2(box.width), round2(box.height)).clip()
        writer.paint(name, PdfMatrix(round2(width), 0, 0, round2(height), round2(box.x - s.cropLeft * width), round2(bottom - s.cropBottom * height)))
        writer.restore()
    }

    // Tw only works on one-byte codes, so the gap after each space is a TJ adjustment.
    private static func justified(_ writer: ContentWriter, _ font: PdfDrawFont, _ text: PlacedText) {
        var items: [PdfObject] = []
        let adjust = round2(-text.spaceExtra * 1000 / text.size)
        let scalars = Array(text.text.unicodeScalars)
        var start = 0
        for k in 0..<scalars.count {
            if scalars[k] != " " || k == scalars.count - 1 { continue }
            items.append(PdfString(bytes: font.encode(String(String.UnicodeScalarView(scalars[start...k]))), isHex: true))
            items.append(PdfNumber(adjust))
            start = k + 1
        }
        items.append(PdfString(bytes: font.encode(String(String.UnicodeScalarView(scalars[start...]))), isHex: true))
        writer.op("TJ", [PdfArray(items)])
    }
}
