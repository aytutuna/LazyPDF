import Foundation

// Twin of windows/LazyPDF.Core/Export/DocxWriter.cs, from Lazy Scan's DocxWriter.cs: the package layout, the inline
// picture and the page setup, grown from one run per paragraph to styles, lists and tables, and deflated.
//
// A row of a table that is shorter than the first reads as blank cells where the C# throws IndexOutOfRangeException.

private typealias Xml = ExportXml

/// The Word document (.docx) of an `ExportDocument`: headings, paragraphs with bold and italic runs, bulleted and
/// numbered lists, tables, and pictures where they stood. Each page after the first starts on a new page. The paper is
/// the first page's size; the margins are what the content leaves free, between 0.25 and 2 inches.
public enum DocxWriter {
    private static let minTwips = 144, maxTwips = 31680
    static let maxTableColumns = 63
    private static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let relNs = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let officeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    public static func make(_ document: ExportDocument) throws -> [UInt8] {
        var media: [ExportImage] = []
        var mediaIndex: [ObjectIdentifier: Int] = [:]
        let (width, height) = paperTwips(document)
        let (top, right, bottom, left) = marginsTwips(document, width, height)
        let body = try self.body(document, width - left - right, &media, &mediaIndex, width, height, top, right, bottom, left)

        var types = Xml.header
        types += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        if media.contains(where: { $0.isJpeg }) { types += "<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>" }
        if media.contains(where: { !$0.isJpeg }) { types += "<Default Extension=\"png\" ContentType=\"image/png\"/>" }
        types += "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
            + "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>"
        let title = document.title.map { !ExportTrim.both($0).isEmpty } ?? false
        if title { types += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>" }
        types += "</Types>"

        var rels = Xml.header
        rels += "<Relationships xmlns=\"\(relNs)\">"
            + "<Relationship Id=\"rId1\" Type=\"\(officeRel)/officeDocument\" Target=\"word/document.xml\"/>"
        if title { rels += "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>" }
        rels += "</Relationships>"

        var documentRels = Xml.header
        documentRels += "<Relationships xmlns=\"\(relNs)\">"
            + "<Relationship Id=\"rId1\" Type=\"\(officeRel)/styles\" Target=\"styles.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"\(officeRel)/numbering\" Target=\"numbering.xml\"/>"
        for i in 0..<media.count {
            documentRels += "<Relationship Id=\"rId\(Xml.i(i + 3))\" Type=\"\(officeRel)/image\" Target=\"media/image\(Xml.i(i + 1)).\(media[i].extension)\"/>"
        }
        documentRels += "</Relationships>"

        var entries: [ExportZipEntry] = [
            ExportZipEntry("[Content_Types].xml", Xml.utf8(types)),
            ExportZipEntry("_rels/.rels", Xml.utf8(rels)),
            ExportZipEntry("word/document.xml", Xml.utf8(body)),
            ExportZipEntry("word/styles.xml", Xml.utf8(styles(document.bodySize))),
            ExportZipEntry("word/numbering.xml", Xml.utf8(numbering(document))),
            ExportZipEntry("word/_rels/document.xml.rels", Xml.utf8(documentRels)),
        ]
        if title, let name = document.title {
            entries.append(ExportZipEntry("docProps/core.xml", Xml.utf8(Xml.header
                + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>"
                + Xml.escape(name) + "</dc:title></cp:coreProperties>")))
        }
        for i in 0..<media.count { entries.append(ExportZipEntry("word/media/image\(i + 1).\(media[i].extension)", media[i].data)) }
        return try ExportZip.make(entries)
    }

    private static func body(_ document: ExportDocument, _ contentTwips: Int, _ media: inout [ExportImage], _ mediaIndex: inout [ObjectIdentifier: Int],
                             _ width: Int, _ height: Int, _ top: Int, _ right: Int, _ bottom: Int, _ left: Int) throws -> String {
        let sb = ExportBuilder(Xml.header)
        sb.append("<w:document xmlns:w=\"\(w)\" xmlns:r=\"\(officeRel)\"")
            .append(" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"")
            .append(" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"")
            .append(" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>")
        var drawing = 0
        var any = false
        for p in 0..<document.pages.count {
            var pageBreak = p > 0
            let blocks = document.pages[p].blocks
            if blocks.isEmpty && pageBreak { sb.append("<w:p><w:pPr><w:pageBreakBefore/></w:pPr></w:p>") }
            for block in blocks {
                try Xml.checkLength(sb)
                any = true
                switch block {
                case let paragraph as ExportParagraph:
                    self.paragraph(sb, paragraph, document.bodySize, pageBreak)
                case let table as ExportTable:
                    if pageBreak { sb.append("<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>") }
                    try self.table(sb, table, contentTwips)
                case let picture as ExportPicture:
                    var number = mediaIndex[ObjectIdentifier(picture.image)] ?? 0
                    if number == 0 {
                        media.append(picture.image)
                        number = media.count
                        mediaIndex[ObjectIdentifier(picture.image)] = number
                    }
                    drawing += 1
                    self.picture(sb, picture, number, drawing, contentTwips, pageBreak)
                default:
                    break
                }
                pageBreak = false
            }
        }
        if !any { sb.append("<w:p/>") }
        sb.append("<w:sectPr><w:pgSz w:w=\"\(Xml.i(width))\" w:h=\"\(Xml.i(height))\"")
        if width > height { sb.append(" w:orient=\"landscape\"") }
        sb.append("/><w:pgMar w:top=\"\(Xml.i(top))\" w:right=\"\(Xml.i(right))\" w:bottom=\"\(Xml.i(bottom))")
            .append("\" w:left=\"\(Xml.i(left))\" w:header=\"\(Xml.i(min(top, 720) / 2))\" w:footer=\"\(Xml.i(min(bottom, 720) / 2))")
            .append("\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>")
        try Xml.checkLength(sb)
        return sb.text
    }

    private static func paragraph(_ sb: ExportBuilder, _ paragraph: ExportParagraph, _ body: Double, _ pageBreak: Bool) {
        sb.append("<w:p><w:pPr>")
        if paragraph.heading > 0 {
            sb.append("<w:pStyle w:val=\"Heading\(Xml.i(paragraph.heading))\"/>")
        } else if paragraph.item != nil {
            sb.append("<w:pStyle w:val=\"ListParagraph\"/>")
        }
        if pageBreak { sb.append("<w:pageBreakBefore/>") }
        if let item = paragraph.item {
            sb.append("<w:numPr><w:ilvl w:val=\"\(Xml.i(item.level))\"/><w:numId w:val=\"\(Xml.i(item.listId))\"/></w:numPr>")
        }
        sb.append("</w:pPr>")
        for run in paragraph.runs { self.run(sb, run, paragraph.heading == 0, body) }
        sb.append("</w:p>")
    }

    private static func run(_ sb: ExportBuilder, _ run: ExportRun, _ style: Bool, _ body: Double) {
        var props = ""
        if style && run.bold { props += "<w:b/>" }
        if style && run.italic { props += "<w:i/>" }
        if style && abs(run.size - body) > 0.6 {
            props += "<w:sz w:val=\"\(Xml.i(ExportString.round(run.size * 2)))\"/><w:szCs w:val=\"\(Xml.i(ExportString.round(run.size * 2)))\"/>"
        }
        sb.append("<w:r>")
        if !props.isEmpty { sb.append("<w:rPr>").append(props).append("</w:rPr>") }
        let pieces = ExportString.split(ExportString.replace(run.text, "\r", ""), "\t")
        for i in 0..<pieces.count {
            if i > 0 { sb.append("<w:tab/>") }
            if !pieces[i].isEmpty { sb.append("<w:t xml:space=\"preserve\">").append(Xml.escape(pieces[i])).append("</w:t>") }
        }
        sb.append("</w:r>")
    }

    // Word stops at 63 columns; what lies beyond joins the last one, with its width.
    static func shares(_ table: ExportTable, _ columns: Int) -> [Double] {
        var share = [Double](repeating: 0, count: columns)
        let widths = table.widths
        var total = 0.0
        for width in widths ?? [] { total += width }
        for c in 0..<table.columns {
            share[min(c, columns - 1)] += total > 0 ? (c < (widths?.count ?? 0) ? widths?[c] ?? 0 : 0) : 1
        }
        return share
    }

    // The cell of a row at a column; the last column holds what lies beyond it.
    static func cell(_ row: [String], _ c: Int, _ columns: Int) -> String {
        if c == columns - 1 && columns < row.count { return row[c...].filter { !$0.isEmpty }.joined(separator: " ") }
        return c < row.count ? row[c] : ""
    }

    private static func table(_ sb: ExportBuilder, _ table: ExportTable, _ contentTwips: Int) throws {
        let columns = min(table.columns, maxTableColumns)
        if columns == 0 { return }
        let share = shares(table, columns)
        let sum = share.reduce(0, +)
        var widths = [Int](repeating: 0, count: columns)
        for c in 0..<columns { widths[c] = Int(saturating32: nanMax(120, share[c] / sum * Double(contentTwips))) }

        sb.append("<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(Xml.i(widths.reduce(0, +)))\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/></w:tblPr><w:tblGrid>")
        for width in widths { sb.append("<w:gridCol w:w=\"\(Xml.i(width))\"/>") }
        sb.append("</w:tblGrid>")
        for row in table.rows {
            try Xml.checkLength(sb)
            sb.append("<w:tr>")
            for c in 0..<columns {
                sb.append("<w:tc><w:tcPr><w:tcW w:w=\"\(Xml.i(widths[c]))\" w:type=\"dxa\"/></w:tcPr><w:p>")
                let text = cell(row, c, columns)
                if !text.isEmpty { sb.append("<w:r><w:t xml:space=\"preserve\">").append(Xml.escape(text)).append("</w:t></w:r>") }
                sb.append("</w:p></w:tc>")
            }
            sb.append("</w:tr>")
        }
        sb.append("</w:tbl><w:p><w:pPr><w:spacing w:after=\"0\"/></w:pPr></w:p>")
    }

    private static func picture(_ sb: ExportBuilder, _ picture: ExportPicture, _ media: Int, _ drawing: Int, _ contentTwips: Int, _ pageBreak: Bool) {
        var cx = Xml.emu(picture.bounds.width), cy = Xml.emu(picture.bounds.height)
        let limit = contentTwips * 635
        if cx > limit {
            cy = max(1, cy * limit / cx)
            cx = limit
        }
        let size = "cx=\"\(Xml.i(cx))\" cy=\"\(Xml.i(cy))\"", name = ExportText.image(drawing)
        sb.append("<w:p>")
        if pageBreak { sb.append("<w:pPr><w:pageBreakBefore/></w:pPr>") }
        sb.append("<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent \(size)/>")
            .append("<wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/><wp:docPr id=\"\(Xml.i(drawing))\" name=\"\(name)\" descr=\"\(name)\"/>")
            .append("<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>")
            .append("<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>")
            .append("<pic:nvPicPr><pic:cNvPr id=\"\(Xml.i(drawing))\" name=\"image\(Xml.i(media)).\(picture.image.extension)\"/><pic:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></pic:cNvPicPr></pic:nvPicPr>")
            .append("<pic:blipFill><a:blip r:embed=\"rId\(Xml.i(media + 2))\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>")
            .append("<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext \(size)/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>")
            .append("</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>")
    }

    private static func styles(_ body: Double) -> String {
        var sb = Xml.header
        sb += "<w:styles xmlns:w=\"\(w)\"><w:docDefaults><w:rPrDefault><w:rPr>"
            + "<w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"Calibri\" w:cs=\"Calibri\"/>"
            + "<w:sz w:val=\"\(Xml.i(ExportString.round(body * 2)))\"/><w:szCs w:val=\"\(Xml.i(ExportString.round(body * 2)))\"/>"
            + "</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"259\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
        let scale = [2.0, 1.6, 1.35, 1.2, 1.1, 1.0]
        for level in 1...6 {
            let size = Xml.i(ExportString.round(body * scale[level - 1] * 2))
            sb += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(Xml.i(level))\"><w:name w:val=\"heading \(Xml.i(level))\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>"
                + "<w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"80\"/><w:outlineLvl w:val=\"\(Xml.i(level - 1))\"/></w:pPr>"
                + "<w:rPr><w:b/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        sb += "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:spacing w:after=\"40\"/><w:ind w:left=\"720\"/></w:pPr></w:style>"
            + "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:uiPriority w:val=\"99\"/><w:semiHidden/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
            + "<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:basedOn w:val=\"TableNormal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr>"
            + "<w:tblPr><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/></w:tblBorders></w:tblPr></w:style>"
            + "</w:styles>"
        return sb
    }

    // One abstract list for bullets and one for numbers; each list of the document is a num of its own, so numbering restarts.
    private static func numbering(_ document: ExportDocument) -> String {
        var sb = Xml.header
        sb += "<w:numbering xmlns:w=\"\(w)\">"
        let bullets = ["•", "◦", "▪", "•"]
        for kind in 0..<2 {
            sb += "<w:abstractNum w:abstractNumId=\"\(Xml.i(kind))\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
            for level in 0..<4 {
                sb += "<w:lvl w:ilvl=\"\(Xml.i(level))\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(kind == 0 ? "bullet" : "decimal")"
                    + "\"/><w:lvlText w:val=\"\(kind == 0 ? bullets[level] : "%\(level + 1).")\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\""
                    + "\(Xml.i(720 + 360 * level))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }
            sb += "</w:abstractNum>"
        }
        var seen = Set<Int>()
        for page in document.pages {
            for block in page.blocks {
                guard let item = (block as? ExportParagraph)?.item, seen.insert(item.listId).inserted else { continue }
                sb += "<w:num w:numId=\"\(Xml.i(item.listId))\"><w:abstractNumId w:val=\"\(item.ordered ? "1" : "0")\"/>"
                if item.ordered { sb += "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"\(Xml.i(max(1, item.number)))\"/></w:lvlOverride>" }
                sb += "</w:num>"
            }
        }
        sb += "</w:numbering>"
        return sb
    }

    static func paperTwips(_ document: ExportDocument) -> (width: Int, height: Int) {
        guard let first = document.pages.first, first.width > 0, first.height > 0 else { return (12240, 15840) }
        func twips(_ points: Double) -> Int { min(max(Int(saturating32: (points * 20).rounded(.toNearestOrEven)), minTwips), maxTwips) }
        return (twips(first.width), twips(first.height))
    }

    // What the content leaves free on every page, kept between a quarter inch and two inches.
    static func marginsTwips(_ document: ExportDocument, _ width: Int, _ height: Int) -> (top: Int, right: Int, bottom: Int, left: Int) {
        var boxes: [(page: ExportPage, bounds: DisplayRect)] = []
        for page in document.pages { for block in page.blocks { boxes.append((page, block.bounds)) } }
        if boxes.isEmpty { return (1440, 1440, 1440, 1440) }
        // The two margins of an axis take at most two thirds of the paper, so the content width stays positive on a stamp-sized page.
        func clamp(_ points: Double, _ limit: Int) -> Int {
            let low = min(360, limit)
            return min(max(Int(saturating32: (points * 20).rounded(.toNearestOrEven)), low), max(low, min(2880, limit)))
        }
        func least(_ value: ((page: ExportPage, bounds: DisplayRect)) -> Double) -> Double {
            var best = value(boxes[0])
            for b in boxes.dropFirst() { best = nanMin(best, value(b)) }
            return best
        }
        let left = clamp(least { $0.bounds.x }, width / 3)
        let top = clamp(least { $0.bounds.y }, height / 3)
        let right = clamp(least { $0.page.width - $0.bounds.x - $0.bounds.width }, width / 3)
        let bottom = clamp(least { $0.page.height - $0.bounds.y - $0.bounds.height }, height / 3)
        return (top, right, bottom, left)
    }
}
