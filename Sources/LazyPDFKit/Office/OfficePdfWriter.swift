import Foundation

// Twin of windows/LazyPDF.Core/Office/Layout/OfficePdfWriter.cs: lays a document out and writes it as a PDF with
// embedded subset fonts, so the text stays selectable.

enum OfficePdfWriter {
    private struct FontKey: Hashable {
        let family: String
        let style: Int
    }

    /// When `contents` is given, it receives the content stream of every page as written. Throws
    /// `InvalidOperationException` (the message is `ExportText.noFont`) when no font can draw the text, and
    /// `PdfReadException` when the page size or margins leave no room or the document runs past `Paginator.maxPages`.
    static func create(_ document: LayoutDocument, _ fonts: FontSource?, contents: ((Int, [UInt8]) -> Void)? = nil) throws -> OfficePdf {
        let layout = try Paginator(document, LayoutFonts(fonts)).run()
        let pdf = try ExportPdf.newDocument()
        let embedder = PdfFontEmbedder(pdf, fonts)

        var order: [FontKey] = []
        var texts: [FontKey: [String]] = [:]
        for page in layout.pages {
            for case .text(let box) in page.boxes {
                let key = FontKey(family: box.family, style: box.style.rawValue)
                if texts[key] == nil {
                    texts[key] = []
                    order.append(key)
                }
                texts[key]!.append(box.text)
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
            let content = try Self.content(pdf, pdf.pages[i], layout.pages[i], drawn)
            contents?(i, content)
            let dictionary = PdfDictionary()
            dictionary["Filter"] = PdfName("FlateDecode")
            pdf.pages[i].dictionary["Contents"] = try pdf.add(PdfStream(dictionary, data: PdfFilterEncoders.flate(content)))
        }
        return OfficePdf(try pdf.saveRewrite(), layout.pages.count, layout.skipped, layout.missing)
    }

    // Everything is rounded to 1/100 point, so that both engines write the same numbers.
    private static func round2(_ value: Double) -> Double { (value * 100).rounded(.toNearestOrAwayFromZero) / 100 + 0.0 }

    private static func channel(_ value: Int) -> Double { (Double(value) / 255.0 * 1000).rounded(.toNearestOrAwayFromZero) / 1000 }

    private static func content(_ pdf: PdfDocument, _ page: PdfPage, _ layout: LayoutPage, _ fonts: [FontKey: PdfDrawFont]) throws -> [UInt8] {
        let writer = ContentWriter()
        var names: [FontKey: String] = [:]
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
            case .text(let text):
                let key = FontKey(family: text.family, style: text.style.rawValue)
                let font = fonts[key]!
                if names[key] == nil { names[key] = ContentResources.add(pdf, resources, "Font", font.reference, "F") }
                setColor(text.color)
                writer.beginText().font(names[key]!, round2(text.size)).moveText(round2(text.x), round2(layout.height - text.baseline))
                if text.spaceExtra > 0 { justified(writer, font, text) } else { writer.show(font.encode(text.text)) }
                writer.endText()
            }
        }
        return writer.toArray()
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
