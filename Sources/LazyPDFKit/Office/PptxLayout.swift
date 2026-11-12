import Foundation

// Twin of windows/LazyPDF.Core/Office/Pptx/PptxLayout.cs: sets the slides of a presentation on pages the size of the slide. The
// text goes through `ParagraphLayout` and `Paginator.emitLine` like Word text. There is no paginator; a shape's text that does
// not fit runs over the edge of the shape, as it does in PowerPoint. A table is measured like one in a document and put on the
// slide whole.

enum PptxLayout {
    private static let wide = 1e7
    private static let maxBoxes = 4_000_000

    /// Throws `PdfReadException` when the slides come to too many boxes.
    static func run(_ presentation: PptxPresentation, _ fonts: LayoutFonts) throws -> LayoutResult {
        var pages: [LayoutPage] = []
        var rightToLeft = 0, complex = 0, total = 0
        for slide in presentation.slides {
            try Task.checkCancellation()
            var boxes: [LayoutBox] = []
            if let background = slide.background {
                if let color = background.color {
                    boxes.append(.rect(PlacedRect(x: 0, y: 0, width: presentation.width, height: presentation.height, color: color)))
                }
                if let backdrop = background.picture {
                    boxes.append(.image(PlacedImage(x: 0, y: 0, width: presentation.width, height: presentation.height, source: backdrop)))
                }
            }
            let number = String(slide.number)
            for shape in slide.shapes {
                if let fill = shape.fill, shape.width > 0, shape.height > 0 {
                    boxes.append(.rect(PlacedRect(x: shape.x, y: shape.y, width: shape.width, height: shape.height, color: fill)))
                }
                if let picture = shape.picture { boxes.append(.image(picture)) }
                for path in shape.paths { boxes.append(.path(path)) }
                if let table = shape.table {
                    let lines = try TableLayout.measure(table.table, fonts, max(1, table.table.columns.reduce(0, +)), wide) { p in
                        if p.rightToLeft { rightToLeft += 1 }
                        if p.complexScript { complex += 1 }
                    }
                    Paginator.emitTable(&boxes, lines, table.x, table.y)
                }
                if let body = shape.body { try text(shape, body, fonts, number, &boxes, &rightToLeft, &complex) }
                if total + boxes.count > maxBoxes { throw PdfReadException(.unsupported, "The presentation is too large.") }
            }
            total += boxes.count
            pages.append(LayoutPage(width: presentation.width, height: presentation.height, boxes: boxes))
        }

        var skipped = presentation.skipped
        func add(_ kind: String, _ count: Int) {
            if count <= 0 { return }
            if let at = skipped.firstIndex(where: { $0.kind == kind }) { skipped[at].count += count } else { skipped.append(SkippedFeature(kind, count)) }
        }
        add(SkippedKinds.rightToLeftText, rightToLeft)
        add(SkippedKinds.complexScript, complex)
        return LayoutResult(pages: pages, skipped: skipped, missing: fonts.missing.sorted())
    }

    private static func text(_ shape: PptxShape, _ body: PptxBody, _ fonts: LayoutFonts, _ number: String, _ boxes: inout [LayoutBox], _ rightToLeft: inout Int, _ complex: inout Int) throws {
        let inner = max(1, shape.width - body.left - body.right)
        let room = shape.height - body.top - body.bottom
        var laid: [ParagraphLines] = []
        for paragraph in body.paragraphs {
            let lines = try ParagraphLayout.run(body.wrap ? paragraph : unwrapped(paragraph), fonts, body.wrap ? inner : wide, wide, { _ in number })
            if lines.rightToLeft { rightToLeft += 1 }
            if lines.complexScript { complex += 1 }
            laid.append(lines)
        }
        let aligns = body.paragraphs.map { $0.align }

        // PowerPoint ignores the space before the first paragraph and after the last one.
        var height = 0.0
        for i in 0..<laid.count {
            height += laid[i].height + (i > 0 ? laid[i].source.before : 0) + (i < laid.count - 1 ? laid[i].source.after : 0)
        }
        var y = shape.y + body.top
        switch body.anchor {
        case .center: y += (room - height) / 2
        case .bottom: y += room - height
        case .top: break
        }
        let left = shape.x + body.left
        for i in 0..<laid.count {
            let lines = laid[i]
            if i > 0 { y += lines.source.before }
            for line in lines.lines {
                Paginator.emitLine(&boxes, line, left + (body.wrap ? 0 : shift(line, aligns[i], inner)), y)
                y += line.height
            }
            if i < laid.count - 1 { y += lines.source.after }
        }
    }

    // Text that does not wrap is laid out on a line without end and then moved so that its alignment holds against the shape.
    private static func unwrapped(_ p: LayoutParagraph) -> LayoutParagraph {
        let q = LayoutParagraph()
        q.runs = p.runs
        q.align = .left
        q.left = p.left
        q.right = 0
        q.firstLine = p.firstLine
        q.before = p.before
        q.after = p.after
        q.lineSpacing = p.lineSpacing
        q.rule = p.rule
        q.labelTab = p.labelTab
        return q
    }

    private static func shift(_ line: LayoutLine, _ align: LayoutAlign, _ inner: Double) -> Double {
        guard let ink = line.atoms.lastIndex(where: { !$0.isBlank }), align == .center || align == .right else { return 0 }
        let end = line.atoms[ink].x + line.atoms[ink].width
        return align == .center ? (inner - (end - line.start)) / 2 - line.start : inner - end
    }
}
