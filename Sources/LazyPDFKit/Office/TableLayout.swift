import Foundation

// Twin of windows/LazyPDF.Core/Office/Layout/TableLayout.cs: measures a table. Column positions, the lines of every
// cell, row heights and which rows must stay together.

/// One line of a cell with the space around it: `lead` is the paragraph's space before (first line only), `height` includes it and the space after.
struct CellSlot {
    let line: LayoutLine
    let lead: Double
    let height: Double
}

final class CellLines {
    let source: LayoutCell
    /// From the left edge of the text area.
    let x: Double
    let width: Double
    var slots: [CellSlot] = []
    /// Rows the cell covers, after a merge too tall for a page has been undone.
    var rowSpan: Int

    init(_ source: LayoutCell, x: Double, width: Double) {
        self.source = source
        self.x = x
        self.width = width
        rowSpan = source.rowSpan
    }

    var content: Double {
        var sum = 0.0
        for s in slots { sum += s.height }
        return sum
    }
}

final class RowLines {
    let source: LayoutRow
    var cells: [CellLines] = []
    var height = 0.0
    /// What the content alone needs, without the row's minimum height.
    var need = 0.0

    init(_ source: LayoutRow) { self.source = source }

    var hasLines: Bool { cells.contains { !$0.slots.isEmpty } }
}

final class TableLines {
    let source: LayoutTable
    var rows: [RowLines] = []
    /// The row that starts the group after the one at the index: rows joined by a vertical merge stay together.
    var next: [Int] = []
    /// Rows repeated at the top of each page the table continues on.
    var header = 0

    init(_ source: LayoutTable) { self.source = source }

    func height(_ from: Int, _ to: Int) -> Double {
        var sum = 0.0
        var r = from
        while r < to {
            sum += rows[r].height
            r += 1
        }
        return sum
    }
}

enum TableLayout {
    private static let tolerance = 0.01

    static func measure(_ table: LayoutTable, _ fonts: LayoutFonts, _ areaWidth: Double, _ bodyHeight: Double,
                        _ count: (ParagraphLines) -> Void) throws -> TableLines {
        let x = columns(table, areaWidth)
        let result = TableLines(table)
        for row in table.rows {
            let lines = RowLines(row)
            for cell in row.cells {
                let from = min(cell.column, x.count - 1), to = min(cell.column + cell.span, x.count - 1)
                let width = x[to] - x[from]
                let made = CellLines(cell, x: x[from], width: width)
                let inner = max(1, width - cell.marginLeft - cell.marginRight)
                for paragraph in cell.paragraphs {
                    let paragraphLines = try ParagraphLayout.run(paragraph, fonts, inner, bodyHeight)
                    count(paragraphLines)
                    let n = paragraphLines.lines.count
                    for k in 0..<n {
                        let line = paragraphLines.lines[k]
                        let lead = k == 0 ? paragraph.before : 0, tail = k == n - 1 ? paragraph.after : 0
                        made.slots.append(CellSlot(line: line, lead: lead, height: lead + line.height + tail))
                    }
                }
                lines.cells.append(made)
            }
            result.rows.append(lines)
        }

        heights(result)
        groups(result)
        // A merge taller than a page cannot be kept in one piece; its cell goes back to one row and breaks across pages like any other.
        var undone = false
        var r = 0
        while r < result.rows.count {
            let next = result.next[r]
            if next - r > 1 && result.height(r, next) > bodyHeight {
                for k in r..<next {
                    for cell in result.rows[k].cells { cell.rowSpan = 1 }
                }
                undone = true
            }
            r = next
        }
        if undone {
            heights(result)
            groups(result)
        }

        var header = 0
        while header < result.rows.count && result.rows[header].source.header { header += 1 }
        while header > 0 && !isStart(result, header) { header -= 1 }
        if header < result.rows.count && result.height(0, header) * 2 <= bodyHeight { result.header = header }
        return result
    }

    private static func isStart(_ table: TableLines, _ row: Int) -> Bool {
        var r = 0
        while r < table.rows.count {
            if r == row { return true }
            if r > row { return false }
            r = table.next[r]
        }
        return row == table.rows.count
    }

    // Column edges from the left of the text area. Columns without a width share what the others leave; a table wider
    // than its room is narrowed to fit instead of running into the margin.
    private static func columns(_ table: LayoutTable, _ areaWidth: Double) -> [Double] {
        var widths = table.columns.map { max(0, $0) }
        let indent = table.align == .left ? min(max(table.indent, 0), max(0, areaWidth - 36)) : 0
        let room = max(36, areaWidth - indent)
        let free = widths.filter { $0 == 0 }.count
        if free > 0 {
            let each = max(room - widths.reduce(0, +), Double(free) * 12) / Double(free)
            for c in 0..<widths.count where widths[c] == 0 { widths[c] = each }
        }
        var total = widths.reduce(0, +)
        if total > room {
            for c in 0..<widths.count { widths[c] *= room / total }
            total = room
        }
        let start: Double
        switch table.align {
        case .center: start = (areaWidth - total) / 2
        case .right: start = areaWidth - total
        default: start = table.indent
        }
        var edges = [Double](repeating: 0, count: widths.count + 1)
        edges[0] = start
        for c in 0..<widths.count { edges[c + 1] = edges[c] + widths[c] }
        return edges
    }

    private static func heights(_ table: TableLines) {
        let rows = table.rows
        for row in rows {
            let exact = row.source.heightExact && row.source.height > 0
            row.need = 0
            for cell in row.cells {
                if cell.rowSpan > 1 { continue }
                row.need = max(row.need, cell.source.marginTop + cell.content + cell.source.marginBottom)
            }
            row.height = exact ? row.source.height : max(row.source.height, row.need)
            if !exact { continue }
            // What does not fit in a fixed height is cut off.
            for cell in row.cells {
                let allowed = row.height - cell.source.marginTop - cell.source.marginBottom
                var used = 0.0
                var keep = 0
                while keep < cell.slots.count && used + cell.slots[keep].height <= allowed + tolerance {
                    used += cell.slots[keep].height
                    keep += 1
                }
                if keep < cell.slots.count { cell.slots = Array(cell.slots[0..<keep]) }
            }
        }

        // A merged cell that needs more than its rows give makes the last of them taller.
        var spanning: [(row: Int, end: Int, cell: CellLines, order: Int)] = []
        for r in 0..<rows.count {
            for cell in rows[r].cells where cell.rowSpan > 1 {
                spanning.append((r, min(rows.count, r + cell.rowSpan), cell, spanning.count))
            }
        }
        spanning.sort { ($0.end, $0.row, $0.order) < ($1.end, $1.row, $1.order) }
        for (row, end, cell, _) in spanning {
            let need = cell.source.marginTop + cell.content + cell.source.marginBottom
            var have = 0.0
            for r in row..<end { have += rows[r].height }
            if need > have { rows[end - 1].height += need - have }
        }
    }

    private static func groups(_ table: TableLines) {
        let rows = table.rows
        var starts: [Int] = []
        var reach = 0
        for r in 0..<rows.count {
            if r >= reach { starts.append(r) }
            reach = max(reach, r + 1)
            for cell in rows[r].cells { reach = max(reach, min(rows.count, r + cell.rowSpan)) }
        }
        table.next = [Int](repeating: 0, count: rows.count)
        for g in 0..<starts.count {
            let end = g + 1 < starts.count ? starts[g + 1] : rows.count
            for r in starts[g]..<end { table.next[r] = end }
        }
    }
}
