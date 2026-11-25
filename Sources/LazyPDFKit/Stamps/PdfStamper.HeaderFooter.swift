import Foundation

// Twin of windows/LazyPDF.Core/Stamps/PdfStamper.HeaderFooter.cs: headers, footers and Bates numbers.

extension PdfStamper {
    func headerFooter(_ id: Int, _ spec: HeaderFooterSpec) throws -> StampRun {
        let targets = self.targets(spec.pages)
        let pageCount = document.pages.count
        let start = Int32(truncatingIfNeeded: spec.startNumber)
        var slots: [(index: Int, texts: [String])] = []
        for index in targets {
            let even = index % 2 == 1
            let header = even ? spec.evenHeader ?? spec.header : spec.header
            let footer = even ? spec.evenFooter ?? spec.footer : spec.footer
            let values = StampTokens.Values(page: Self.wrapped(start, index), pages: Self.wrapped(start, pageCount - 1),
                                            bates: spec.bates.map { $0.format($0.start &+ slots.count) } ?? "", spec: spec)
            let texts = [header.left, header.center, header.right, footer.left, footer.center, footer.right]
                .map { StampTokens.expand($0, values) }
            if texts.contains(where: { !$0.isEmpty }) { slots.append((index, texts)) }
        }
        if slots.isEmpty { return StampRun(id: id, pages: 0, nextBates: spec.bates?.start ?? 0, missing: []) }

        let font = try self.font(spec.fontFamily, spec.fontStyle, slots.flatMap { $0.texts })
        let size = spec.fontSize
        let label = [spec.header.left, spec.header.center, spec.header.right, spec.footer.left, spec.footer.center, spec.footer.right]
            .filter { !$0.isEmpty }.joined(separator: " | ")
        let kind: StampKind = spec.bates == nil ? .headerFooter : .bates

        for (index, texts) in slots {
            let page = document.pages[index]
            let canvas = StampCanvas(page, id, false)
            canvas.writer.fillRgb(spec.color.r, spec.color.g, spec.color.b)
            let top = canvas.height - spec.marginTop - font.ascent * size
            let bottom = spec.marginBottom - font.descent * size
            Self.drawBand(canvas, id, font, size, spec.marginX, top, Array(texts[0..<3]), "Header")
            Self.drawBand(canvas, id, font, size, spec.marginX, bottom, Array(texts[3..<6]), "Footer")
            try finish(page, canvas, id, kind, label, false, font.reference, nil, nil, nil)
        }
        return StampRun(id: id, pages: slots.count, nextBates: spec.bates.map { $0.start &+ slots.count } ?? 0, missing: font.missing)
    }

    // The C# adds ints without a check, so a start number near the top wraps at 32 bits.
    private static func wrapped(_ start: Int32, _ count: Int) -> Int {
        Int(start &+ Int32(truncatingIfNeeded: count))
    }

    private static func drawBand(_ canvas: StampCanvas, _ id: Int, _ font: PdfDrawFont, _ size: Double, _ marginX: Double,
                                 _ baseline: Double, _ texts: [String], _ subtype: String) {
        if texts.allSatisfy({ $0.isEmpty }) { return }
        canvas.beginArtifact("Pagination", subtype)
        let writer = canvas.writer.beginText().font(StampStreams.fontName(id), size)
        for (i, text) in texts.enumerated() where !text.isEmpty {
            let width = font.width(text, size)
            let x: Double
            switch i {
            case 0: x = marginX
            case 1: x = (canvas.width - width) / 2
            default: x = canvas.width - marginX - width
            }
            writer.textMatrix(PdfMatrix.translate(x, baseline)).show(font, text, size)
        }
        writer.endText()
        canvas.endArtifact()
    }
}
