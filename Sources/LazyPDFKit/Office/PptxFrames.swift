import Foundation

// Twin of windows/LazyPDF.Core/Office/Pptx/PptxFrames.cs: pictures and graphic frames. Tables are drawn, charts, diagrams and
// embedded objects are counted.

extension PptxReader {
    private static let defaultCellSide = 7.2, defaultCellEdge = 3.6

    func pic(_ pic: OfficeXmlElement, _ scope: Scope, _ context: Affine) throws -> PptxShape? {
        let p = Self.p, a = DocxReader.a
        let spPr = pic.child(p, "spPr")
        let nvPr = pic.child(p, "nvPicPr")?.child(p, "nvPr")
        let media = nvPr?.elements.contains { ["audioFile", "videoFile", "wavAudioFile", "quickTimeFile"].contains($0.name) } == true
        if media { skip(PptxSkipped.media) }
        var layoutPr: OfficeXmlElement?
        var masterPr: OfficeXmlElement?
        if let ph = nvPr?.child(p, "ph") {
            let type = ph.attribute("type")
            let index = Int(PptxColors.clamp(DocxReader.number(ph.attribute("idx")) ?? 0, 0, Double(Int32.max)))
            let layoutPh = scope.layout.flatMap { Self.match($0.placeholders, type, index, true) }
            let masterPh = Self.match(scope.master.placeholders, layoutPh?.type ?? type, layoutPh?.index ?? index, false)
            layoutPr = layoutPh?.shape.child(p, "spPr")
            masterPr = masterPh?.shape.child(p, "spPr")
        }
        guard let x = Self.readXfrm(spPr?.child(a, "xfrm") ?? layoutPr?.child(a, "xfrm") ?? masterPr?.child(a, "xfrm")) else {
            if !media { skip(PptxSkipped.shape) }
            return nil
        }

        let matrix = context.multiply(Self.placement(x))
        let frame = Self.uncover(matrix, x.width, x.height)
        var image: PlacedImage?
        if let blipFill = pic.child(p, "blipFill") {
            if let source = try picture(blipFill, scope.relationships, frame.width, frame.height) {
                image = PlacedImage(x: frame.x, y: frame.y, width: frame.width, height: frame.height, source: source,
                                    rotation: frame.turned ? frame.rotation : 0, flipH: frame.flipH)
            }
        } else {
            skip(SkippedKinds.unreadablePicture)
        }

        var paths: [PlacedPath] = []
        if let line = Self.lineOf(spPr, layoutPr, masterPr, pic.child(p, "style"), scope) {
            paths.append(PlacedPath(commands: PptxGeometry.build("rect", x.width, x.height, [:]).map { Self.place(matrix, $0) }, fill: nil, stroke: Self.stroke(line)))
        }
        if image == nil && paths.isEmpty { return nil }
        return PptxShape(x: frame.x, y: frame.y, width: frame.width, height: frame.height, paths: paths, picture: image)
    }

    func graphicFrame(_ frame: OfficeXmlElement, _ scope: Scope, _ context: Affine) throws -> PptxShape? {
        let data = frame.child(DocxReader.a, "graphic")?.child(DocxReader.a, "graphicData")
        let uri = data?.attribute("uri") ?? ""
        if XlsxReader.endsWith(uri, "/table"), let table = data?.child(DocxReader.a, "tbl") { return try makeTable(frame, table, scope, context) }
        if XlsxReader.contains(uri, "chart") {
            skip(PptxSkipped.chart)
        } else if XlsxReader.endsWith(uri, "/diagram") {
            skip(PptxSkipped.smartArt)
        } else if XlsxReader.endsWith(uri, "/ole") || Self.children(data).contains(where: { $0.uri == Self.p && $0.name == "oleObj" }) {
            skip(PptxSkipped.embeddedObject)
        } else {
            skip(PptxSkipped.shape)
        }
        return nil
    }

    private func makeTable(_ frame: OfficeXmlElement, _ table: OfficeXmlElement, _ scope: Scope, _ context: Affine) throws -> PptxShape? {
        let a = DocxReader.a
        let grid = table.child(a, "tblGrid")?.elements(a, "gridCol") ?? []
        let rows = table.elements(a, "tr")
        guard let x = Self.readXfrm(frame.child(Self.p, "xfrm")), !grid.isEmpty, !rows.isEmpty,
              grid.count <= limits.maxTableColumns, rows.count <= limits.maxTableRows else {
            skip(PptxSkipped.shape)
            return nil
        }
        if table.child(a, "tblPr")?.child(a, "tableStyleId") != nil { skip(PptxSkipped.tableStyle) }

        // A table keeps its sizes through a group's scale, but not a group's turn.
        let scaleX = Affine.length(context.a, context.b), scaleY = Affine.length(context.c, context.d)
        func size(_ emu: Double?, _ scale: Double) -> Double { PptxColors.clamp((emu ?? 0) / Self.emuPerPoint, 0, PptxLimits.maxSide) * scale }
        let columns = grid.map { size(DocxReader.number($0.attribute("w")), scaleX) }

        let layout = LayoutTable()
        layout.columns = columns
        var covered = [[LayoutCell?]](repeating: [LayoutCell?](repeating: nil, count: columns.count), count: rows.count)
        for r in 0..<rows.count {
            try Task.checkCancellation()
            let row = LayoutRow()
            row.height = size(DocxReader.number(rows[r].attribute("h")), scaleY)
            var column = 0
            for tc in rows[r].elements(a, "tc") {
                let at = column
                column += 1
                if at >= columns.count { break }
                if Self.isOn(tc.attribute("hMerge")) || Self.isOn(tc.attribute("vMerge")) { continue }
                // A cell under an earlier span is ignored, as PowerPoint does; this also bounds the work to rows x columns.
                if covered[r][at] != nil { continue }
                let cell = try makeCell(tc, at, min(Self.count(tc, "gridSpan"), columns.count - at), min(Self.count(tc, "rowSpan"), rows.count - r), scope)
                row.cells.append(cell)
                for i in r..<(r + cell.rowSpan) {
                    for k in at..<(at + cell.span) { covered[i][k] = cell }
                }
            }
            layout.rows.append(row)
        }
        Self.edges(layout, covered)
        // Cells, borders and margins were read from the first column; a right-to-left table puts that column on the right.
        if PptxRunProps.flag(table.child(a, "tblPr")?.attribute("rtl")) == true {
            layout.mirror()
        }

        let corner = context.apply(x.x, x.y)
        return PptxShape(x: corner.x, y: corner.y, width: columns.reduce(0, +), table: PptxTable(x: corner.x, y: corner.y, table: layout))
    }

    private static func isOn(_ value: String?) -> Bool { value == "1" || value == "true" }

    private static func count(_ tc: OfficeXmlElement, _ name: String) -> Int { Int(PptxColors.clamp(DocxReader.number(tc.attribute(name)) ?? 1, 1, 1000)) }

    private func makeCell(_ tc: OfficeXmlElement, _ column: Int, _ span: Int, _ rowSpan: Int, _ scope: Scope) throws -> LayoutCell {
        let a = DocxReader.a
        let tcPr = tc.child(a, "tcPr")
        let paragraphs = try tc.child(a, "txBody").map { try makeParagraphs($0, [defaultStyle], scope.colors, PptxBodyProps(), nil).0 } ?? []
        let fill = fillOf(tcPr, scope.colors)
        if let fill, fill.gradient, fill.color != nil { skip(PptxSkipped.gradient) }
        func margin(_ name: String, _ fallback: Double) -> Double {
            DocxReader.number(tcPr?.attribute(name)).map { PptxColors.clamp($0 / Self.emuPerPoint, 0, PptxLimits.maxSide) } ?? fallback
        }
        let cell = LayoutCell()
        cell.column = column
        cell.span = span
        cell.rowSpan = rowSpan
        cell.paragraphs = paragraphs
        cell.fill = fill?.color
        cell.left = Self.border(tcPr?.child(a, "lnL"), scope.colors)
        cell.right = Self.border(tcPr?.child(a, "lnR"), scope.colors)
        cell.top = Self.border(tcPr?.child(a, "lnT"), scope.colors)
        cell.bottom = Self.border(tcPr?.child(a, "lnB"), scope.colors)
        cell.marginLeft = margin("marL", Self.defaultCellSide)
        cell.marginRight = margin("marR", Self.defaultCellSide)
        cell.marginTop = margin("marT", Self.defaultCellEdge)
        cell.marginBottom = margin("marB", Self.defaultCellEdge)
        switch tcPr?.attribute("anchor") {
        case "ctr": cell.vAlign = .center
        case "b": cell.vAlign = .bottom
        default: cell.vAlign = .top
        }
        return cell
    }

    private static func border(_ ln: OfficeXmlElement?, _ colors: PptxColors) -> LayoutBorder? {
        guard let ln else { return nil }
        let info = LineInfo()
        info.width = 1
        applyLine(info, ln, colors, nil)
        guard !info.none, let color = info.color, let width = info.width, width > 0 else { return nil }
        return LayoutBorder(width: width, color: color)
    }

    // Two cells that meet at an edge may both state a border; the wider one is drawn, the first on a tie.
    private static func edges(_ table: LayoutTable, _ covered: [[LayoutCell?]]) {
        func wider(_ a: LayoutBorder?, _ b: LayoutBorder?) -> LayoutBorder? {
            guard let a else { return b }
            guard let b else { return a }
            return b.width > a.width ? b : a
        }
        for (r, row) in table.rows.enumerated() {
            for cell in row.cells {
                let right = cell.column + cell.span, below = r + cell.rowSpan
                if right < covered[r].count, let next = covered[r][right], next !== cell {
                    let border = wider(cell.right, next.left)
                    cell.right = border
                    next.left = border
                }
                if below < covered.count, let under = covered[below][cell.column], under !== cell {
                    let border = wider(cell.bottom, under.top)
                    cell.bottom = border
                    under.top = border
                }
            }
        }
    }
}
