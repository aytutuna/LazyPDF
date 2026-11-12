import Foundation

// Twin of windows/LazyPDF.Core/Office/Docx/DocxTable.cs: tables, with grid, spans, vertical merges, borders, shading,
// margins, and the table styles that supply them.

private let maxTableColumns = 63
private let maxTableRows = 5000
private let maxTableCells = 100_000

private struct TblEdge {
    var set = false
    var border: LayoutBorder?
}

private struct TblCandidate {
    var explicit = false
    var border: LayoutBorder?
}

/// The six border slots of a table or the four of a cell; a later layer replaces only the slots it names.
private struct TblEdges {
    var top = TblEdge(), left = TblEdge(), bottom = TblEdge(), right = TblEdge(), insideH = TblEdge(), insideV = TblEdge()

    mutating func apply(_ borders: OfficeXmlElement?, _ theme: DocxTheme) {
        guard let borders else { return }
        let w = DocxReader.w
        for e in borders.elements {
            guard e.uri == w, let val = e.attribute(w, "val") else { continue }
            var edge: TblEdge
            if val == "nil" || val == "none" {
                edge = TblEdge(set: true, border: nil)
            } else {
                let width = DocxReader.number(e.attribute(w, "sz")).map { min(max($0 / 8, 0.25), 12) } ?? 0.5
                let color = DocxReader.hex(e.attribute(w, "color")) ?? e.attribute(w, "themeColor").flatMap { theme.color($0) } ?? 0
                edge = TblEdge(set: true, border: LayoutBorder(width: width, color: color))
            }
            switch e.name {
            case "top": top = edge
            case "left", "start": left = edge
            case "bottom": bottom = edge
            case "right", "end": right = edge
            case "insideH": insideH = edge
            case "insideV": insideV = edge
            default: break
            }
        }
    }
}

private struct TblMargins {
    var top = 0.0, right = 5.4, bottom = 0.0, left = 5.4

    mutating func apply(_ mar: OfficeXmlElement?) {
        guard let mar else { return }
        let w = DocxReader.w
        for e in mar.elements {
            guard e.uri == w, let twips = DocxReader.number(e.attribute(w, "w")) else { continue }
            let points = min(max(twips / 20, 0), 144)
            switch e.name {
            case "top": top = points
            case "left", "start": left = points
            case "bottom": bottom = points
            case "right", "end": right = points
            default: break
            }
        }
    }
}

private final class TblCellInfo {
    let cell: LayoutCell
    let row: Int
    let table: TblEdges
    let own: TblEdges
    /// The edges of the last cell that continues this one downward; its bottom is the merged cell's bottom.
    var continued: (table: TblEdges, own: TblEdges, row: Int)?
    var top = TblCandidate(), right = TblCandidate(), bottom = TblCandidate(), left = TblCandidate()

    init(_ cell: LayoutCell, _ row: Int, _ table: TblEdges, _ own: TblEdges) {
        self.cell = cell
        self.row = row
        self.table = table
        self.own = own
    }
}

private struct TblLook {
    var firstRow = false, lastRow = false, firstColumn = false, lastColumn = false, bandRows = false, bandColumns = false
}

/// What a cell takes from the table style layers, the table's own properties and its own, in that order.
private struct TblCellFormat {
    var table = TblEdges()
    var own = TblEdges()
    var margin = TblMargins()
    var fill: Int?
    var vAlign = LayoutVAlign.top

    init(_ theme: DocxTheme, _ layers: [OfficeXmlElement], _ tblPr: OfficeXmlElement?, _ tcPr: OfficeXmlElement?) {
        let w = DocxReader.w
        for layer in layers {
            table.apply(layer.child(w, "tblPr")?.child(w, "tblBorders"), theme)
            margin.apply(layer.child(w, "tblPr")?.child(w, "tblCellMar"))
            cell(layer.child(w, "tcPr"), theme)
        }
        table.apply(tblPr?.child(w, "tblBorders"), theme)
        margin.apply(tblPr?.child(w, "tblCellMar"))
        shade(tblPr?.child(w, "shd"), theme)
        cell(tcPr, theme)
    }

    private mutating func cell(_ tcPr: OfficeXmlElement?, _ theme: DocxTheme) {
        guard let tcPr else { return }
        let w = DocxReader.w
        own.apply(tcPr.child(w, "tcBorders"), theme)
        margin.apply(tcPr.child(w, "tcMar"))
        shade(tcPr.child(w, "shd"), theme)
        switch tcPr.child(w, "vAlign")?.attribute(w, "val") {
        case "center": vAlign = .center
        case "bottom": vAlign = .bottom
        case "top": vAlign = .top
        default: break
        }
    }

    // A solid pattern paints with its color; any other pattern is taken as its fill alone.
    private mutating func shade(_ shd: OfficeXmlElement?, _ theme: DocxTheme) {
        let w = DocxReader.w
        guard let shd, let val = shd.attribute(w, "val") else { return }
        if val == "nil" {
            fill = nil
        } else if val == "solid" {
            fill = DocxReader.hex(shd.attribute(w, "color")) ?? fill
        } else if let rgb = DocxReader.hex(shd.attribute(w, "fill")) {
            fill = rgb
        } else if let name = shd.attribute(w, "themeFill"), let themed = theme.color(name) {
            fill = themed
        } else if shd.attribute(w, "fill") == "auto" {
            fill = nil
        }
    }
}

extension DocxReader {
    func table(_ tbl: OfficeXmlElement) throws {
        let w = Self.w
        let rows = tbl.elements(w, "tr")
        var columns = tbl.child(w, "tblGrid")?.elements(w, "gridCol").count ?? 0
        var cellCount = 0
        for tr in rows {
            var at = Self.gridBefore(tr)
            for tc in tr.elements(w, "tc") {
                at += Self.span(tc.child(w, "tcPr"))
                cellCount += 1
            }
            columns = max(columns, at)
        }
        if inCell || inBand || rows.isEmpty || rows.count > maxTableRows || columns == 0 || columns > maxTableColumns
            || tableCells + cellCount > maxTableCells {
            // A table inside a table or a band is read as its paragraphs in order.
            skip("table")
            for row in rows {
                for tc in row.elements(w, "tc") { try readBlocks(tc) }
            }
            return
        }
        tableCells += cellCount

        let tblPr = tbl.child(w, "tblPr")
        let chain = styles.table(tblPr?.child(w, "tblStyle")?.attribute(w, "val"))
        let styleKey = chain.last?.id ?? ""
        let look = Self.readLook(tblPr)
        let rowBand = Self.band(tblPr, "tblStyleRowBandSize")
        let columnBand = Self.band(tblPr, "tblStyleColBandSize")

        var widths = [Double](repeating: 0, count: columns)
        var gridColumns = 0
        for g in tbl.child(w, "tblGrid")?.elements(w, "gridCol") ?? [] where gridColumns < columns {
            widths[gridColumns] = min(max((Self.number(g.attribute(w, "w")) ?? 0) / 20, 0), 14400)
            gridColumns += 1
        }
        var preferred: [(column: Int, span: Int, width: Double)] = []

        var outRows: [LayoutRow] = []
        var infos: [TblCellInfo] = []
        var open = [TblCellInfo?](repeating: nil, count: columns)
        for r in 0..<rows.count {
            let tr = rows[r]
            let trPr = tr.child(w, "trPr")
            var cells: [LayoutCell] = []
            var carried = [TblCellInfo?](repeating: nil, count: columns)
            var column = Self.gridBefore(tr)
            for tc in tr.elements(w, "tc") {
                try Task.checkCancellation()
                let tcPr = tc.child(w, "tcPr")
                let span = min(Self.span(tcPr), columns - column)
                if span <= 0 { break }

                let conditions = Self.conditions(look, r, rows.count, column, span, columns, rowBand, columnBand)
                let layers = Self.layers(chain, conditions)
                let format = TblCellFormat(theme, layers, tblPr, tcPr)
                if let tcW = tcPr?.child(w, "tcW"), tcW.attribute(w, "type") == nil || tcW.attribute(w, "type") == "dxa",
                   let width = Self.number(tcW.attribute(w, "w")), width > 0 {
                    preferred.append((column, span, width / 20))
                }

                let merge = tcPr?.child(w, "vMerge")
                let continues = merge != nil && (merge!.attribute(w, "val") == nil || merge!.attribute(w, "val") == "continue")
                if continues, let above = open[column], above.cell.column == column, above.cell.span == span {
                    above.cell.rowSpan += 1
                    above.continued = (format.table, format.own, r)
                    for c in column..<(column + span) { carried[c] = above }
                    column += span
                    continue
                }

                let made = LayoutCell()
                made.column = column
                made.span = span
                made.paragraphs = try cellContent(tc, styleKey + "|" + conditions.joined(separator: ","), layers)
                made.fill = format.fill
                made.marginTop = format.margin.top
                made.marginRight = format.margin.right
                made.marginBottom = format.margin.bottom
                made.marginLeft = format.margin.left
                made.vAlign = format.vAlign
                let info = TblCellInfo(made, r, format.table, format.own)
                cells.append(made)
                infos.append(info)
                if merge != nil {
                    for c in column..<(column + span) { carried[c] = info }
                }
                column += span
            }
            open = carried

            let row = LayoutRow()
            row.cells = cells
            if let trHeight = trPr?.child(w, "trHeight"), let twips = Self.number(trHeight.attribute(w, "val")) {
                row.height = min(max(twips / 20, 0), 1584)
                row.heightExact = trHeight.attribute(w, "hRule") == "exact"
            }
            if let header = trPr?.child(w, "tblHeader") { row.header = Self.on(header) }
            if let cant = trPr?.child(w, "cantSplit") { row.cantSplit = Self.on(cant) }
            outRows.append(row)
        }

        if gridColumns == 0 {
            for (column, span, width) in preferred where (column..<(column + span)).allSatisfy({ widths[$0] == 0 }) {
                for c in column..<(column + span) { widths[c] = width / Double(span) }
            }
        }
        Self.resolveBorders(infos, outRows.count, columns)

        let indent = Self.number(tblPr?.child(w, "tblInd")?.attribute(w, "w")).map { min(max($0 / 20, -1584), 1584) } ?? 0
        let made = LayoutTable()
        made.columns = widths
        made.indent = indent
        switch tblPr?.child(w, "jc")?.attribute(w, "val") {
        case "center": made.align = .center
        case "right", "end": made.align = .right
        default: made.align = .left
        }
        made.rows = outRows
        blocks.append(made)
    }

    private static func gridBefore(_ tr: OfficeXmlElement) -> Int {
        let w = Self.w
        return Int(min(max(number(tr.child(w, "trPr")?.child(w, "gridBefore")?.attribute(w, "val")) ?? 0, 0), Double(maxTableColumns)))
    }

    private static func span(_ tcPr: OfficeXmlElement?) -> Int {
        let w = Self.w
        return Int(min(max(number(tcPr?.child(w, "gridSpan")?.attribute(w, "val")) ?? 1, 1), Double(maxTableColumns)))
    }

    private static func band(_ tblPr: OfficeXmlElement?, _ name: String) -> Int {
        max(1, Int(min(max(number(tblPr?.child(w, name)?.attribute(w, "val")) ?? 1, 0), 1000)))
    }

    private static func readLook(_ tblPr: OfficeXmlElement?) -> TblLook {
        guard let e = tblPr?.child(w, "tblLook") else { return TblLook() }
        var mask: UInt32 = 0
        if let text = e.attribute(w, "val"), !text.isEmpty, text.utf8.count <= 8,
           text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }) {
            mask = UInt32(text, radix: 16) ?? 0
        }
        func flag(_ name: String, _ bit: UInt32) -> Bool {
            if let text = e.attribute(w, name) { return text == "1" || text == "true" || text == "on" }
            return mask & bit != 0
        }
        return TblLook(firstRow: flag("firstRow", 0x20), lastRow: flag("lastRow", 0x40), firstColumn: flag("firstColumn", 0x80),
                    lastColumn: flag("lastColumn", 0x100), bandRows: !flag("noHBand", 0x200), bandColumns: !flag("noVBand", 0x400))
    }

    // The conditional parts of a table style that apply to a cell, in the order they are laid on: later ones win.
    private static func conditions(_ look: TblLook, _ row: Int, _ rows: Int, _ column: Int, _ span: Int, _ columns: Int,
                                   _ rowBand: Int, _ columnBand: Int) -> [String] {
        let firstRow = look.firstRow && row == 0, lastRow = look.lastRow && row == rows - 1
        let firstColumn = look.firstColumn && column == 0, lastColumn = look.lastColumn && column + span == columns
        var list: [String] = []
        if look.bandColumns && !firstColumn && !lastColumn {
            list.append((column - (look.firstColumn ? 1 : 0)) / columnBand % 2 == 0 ? "band1Vert" : "band2Vert")
        }
        if look.bandRows && !firstRow && !lastRow {
            list.append((row - (look.firstRow ? 1 : 0)) / rowBand % 2 == 0 ? "band1Horz" : "band2Horz")
        }
        if lastColumn { list.append("lastCol") }
        if firstColumn { list.append("firstCol") }
        if lastRow { list.append("lastRow") }
        if firstRow { list.append("firstRow") }
        return list
    }

    private static func layers(_ chain: [DocxStyle], _ conditions: [String]) -> [OfficeXmlElement] {
        var layers = chain.map { $0.source }
        for condition in conditions {
            for style in chain {
                layers.append(contentsOf: style.source.elements(w, "tblStylePr").filter { $0.attribute(w, "type") == condition })
            }
        }
        return layers
    }

    private func cellContent(_ tc: OfficeXmlElement, _ key: String, _ layers: [OfficeXmlElement]) throws -> [LayoutParagraph] {
        let outer = blocks
        blocks = []
        (inCell, tableKey, tableLayers) = (true, key, layers)
        try readBlocks(tc)
        let paragraphs = blocks.compactMap { $0 as? LayoutParagraph }
        (inCell, tableKey, tableLayers) = (false, "", [])
        blocks = outer
        return paragraphs
    }

    // ---- borders ----

    private static func pick(_ table: TblEdges, _ own: TblEdges, _ side: Int, _ outer: Bool) -> TblCandidate {
        let named: TblEdge
        switch side {
        case 0: named = own.top
        case 1: named = own.right
        case 2: named = own.bottom
        default: named = own.left
        }
        if named.set { return TblCandidate(explicit: true, border: named.border) }
        let edge: TblEdge
        switch side {
        case 0: edge = outer ? table.top : table.insideH
        case 1: edge = outer ? table.right : table.insideV
        case 2: edge = outer ? table.bottom : table.insideH
        default: edge = outer ? table.left : table.insideV
        }
        return TblCandidate(explicit: false, border: edge.border)
    }

    // Two cells share an edge; the one named in the cell's own borders wins over the table's, then the wider, then the darker.
    // The cell above or to the left is passed first so that both cells agree on a tie.
    private static func resolve(_ first: TblCandidate, _ second: TblCandidate) -> LayoutBorder? {
        if first.explicit != second.explicit { return first.explicit ? first.border : second.border }
        guard let a = first.border else { return second.border }
        guard let b = second.border else { return a }
        if a.width != b.width { return a.width > b.width ? a : b }
        return brightness(b.color) < brightness(a.color) ? b : a
    }

    private static func brightness(_ rgb: Int) -> Int { (rgb >> 16 & 0xFF) + (rgb & 0xFF) + 2 * (rgb >> 8 & 0xFF) }

    // The neighbor across an edge is the cell at the edge's first row or column, so a cell facing two smaller ones
    // compares itself with the first.
    private static func resolveBorders(_ infos: [TblCellInfo], _ rows: Int, _ columns: Int) {
        var grid = [[TblCellInfo?]](repeating: [TblCellInfo?](repeating: nil, count: columns), count: rows)
        for info in infos {
            for r in info.row..<min(rows, info.row + info.cell.rowSpan) {
                for c in info.cell.column..<(info.cell.column + info.cell.span) { grid[r][c] = info }
            }
        }
        for info in infos {
            let cell = info.cell
            let end = info.row + cell.rowSpan, right = cell.column + cell.span
            let below = info.continued.map { ($0.table, $0.own) } ?? (info.table, info.own)
            info.top = pick(info.table, info.own, 0, info.row == 0)
            info.right = pick(info.table, info.own, 1, right == columns)
            info.bottom = pick(below.0, below.1, 2, end == rows)
            info.left = pick(info.table, info.own, 3, cell.column == 0)
        }
        for info in infos {
            let cell = info.cell
            let end = info.row + cell.rowSpan, right = cell.column + cell.span
            if info.row > 0, let up = grid[info.row - 1][cell.column] { cell.top = resolve(up.bottom, info.top) } else { cell.top = info.top.border }
            if end < rows, let down = grid[end][cell.column] { cell.bottom = resolve(info.bottom, down.top) } else { cell.bottom = info.bottom.border }
            if cell.column > 0, let before = grid[info.row][cell.column - 1] { cell.left = resolve(before.right, info.left) } else { cell.left = info.left.border }
            if right < columns, let after = grid[info.row][right] { cell.right = resolve(info.right, after.left) } else { cell.right = info.right.border }
        }
    }
}
