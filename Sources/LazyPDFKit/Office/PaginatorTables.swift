import Foundation

// Twin of windows/LazyPDF.Core/Office/Layout/PaginatorTables.cs: tables on pages. Rows go on one group at a time (a
// group is rows joined by a vertical merge). A group that does not fit moves to a fresh page; a single row whose lines
// do not fit is cut between lines. Header rows come back at the top of every page the table continues on.

extension Paginator {
    private final class RowProgress {
        /// Lines of each cell already placed.
        var taken: [Int]
        /// Height of the pieces already placed.
        var used = 0.0

        init(_ cells: Int) { taken = [Int](repeating: 0, count: cells) }
    }

    func placeTable(_ table: TableLines, _ section: LayoutSection) throws {
        // Only a page with something on it gains by starting a fresh one.
        var movable = pages[pages.count - 1].hasContent
        let body = pages[pages.count - 1].bottom - pages[pages.count - 1].top
        var progress: RowProgress?
        var i = 0
        while i < table.rows.count {
            try Task.checkCancellation()
            let page = pages[pages.count - 1]
            let room = page.bottom - page.y + Self.tolerance
            let next = table.next[i]
            let row = table.rows[i]
            if progress == nil {
                let height = table.height(i, next)
                var whole = height <= room
                if !whole {
                    let cut = next == i + 1 && row.hasLines && row.need > room && (!row.source.cantSplit || !movable || height > body)
                    if cut {
                        progress = RowProgress(row.cells.count)
                    } else if movable {
                        try advanceTable(table, section, i)
                        movable = false
                        continue
                    } else {
                        whole = true
                    }
                }
                if whole {
                    Self.placeRows(page, table, i, next, section.page.left)
                    page.y += height
                    page.hasContent = true
                    movable = true
                    i = next
                    continue
                }
            }

            let current = progress!
            var take = [Int](repeating: 0, count: row.cells.count)
            var any = false
            for c in 0..<take.count {
                let cell = row.cells[c]
                let taken = current.taken[c]
                var used = taken == 0 ? cell.source.marginTop : 0
                var k = 0
                while taken + k < cell.slots.count && used + cell.slots[taken + k].height <= room {
                    used += cell.slots[taken + k].height
                    k += 1
                }
                if taken + k == cell.slots.count && k > 0 && used + cell.source.marginBottom > room { k -= 1 }
                take[c] = k
                any = any || k > 0
            }
            if !any {
                if movable {
                    try advanceTable(table, section, i)
                    movable = false
                    continue
                }
                // Nothing fits even here, so each cell gives one line to keep the table moving.
                for c in 0..<take.count { take[c] = current.taken[c] < row.cells[c].slots.count ? 1 : 0 }
            }

            var done = true
            var piece = 0.0
            for c in 0..<take.count {
                let cell = row.cells[c]
                let taken = current.taken[c]
                let finished = taken + take[c] == cell.slots.count
                done = done && finished
                var used = (taken == 0 ? cell.source.marginTop : 0) + (finished ? cell.source.marginBottom : 0)
                for k in 0..<take[c] { used += cell.slots[taken + k].height }
                piece = max(piece, used)
            }
            if done { piece = max(piece, min(row.height - current.used, room - Self.tolerance)) }
            Self.emitRowPiece(page, row, section.page.left, page.y, piece, current.taken, take, current.used == 0, done)
            page.y += piece
            page.hasContent = true
            current.used += piece
            for c in 0..<take.count { current.taken[c] += take[c] }
            if done {
                progress = nil
                movable = true
                i = next
            } else {
                try advanceTable(table, section, i)
                movable = false
            }
        }
    }

    private func advanceTable(_ table: TableLines, _ section: LayoutSection, _ row: Int) throws {
        try newPage(section, hard: false)
        if table.header == 0 || row < table.header { return }
        let page = pages[pages.count - 1]
        Self.placeRows(page, table, 0, table.header, section.page.left)
        page.y += table.height(0, table.header)
        page.hasContent = true
    }

    private static func placeRows(_ page: Page, _ table: TableLines, _ from: Int, _ to: Int, _ originX: Double) {
        let parts = CellBoxes()
        var y = page.y
        for r in from..<to {
            for cell in table.rows[r].cells {
                let height = table.height(r, min(to, r + cell.rowSpan))
                emitCell(parts, cell, originX, y, height, 0, cell.slots.count, true, true)
            }
            y += table.rows[r].height
        }
        parts.addTo(&page.boxes)
    }

    private static func emitRowPiece(_ page: Page, _ row: RowLines, _ originX: Double, _ y: Double, _ height: Double,
                                     _ from: [Int], _ count: [Int], _ first: Bool, _ last: Bool) {
        let parts = CellBoxes()
        for c in 0..<row.cells.count { emitCell(parts, row.cells[c], originX, y, height, from[c], from[c] + count[c], first, last) }
        parts.addTo(&page.boxes)
    }

    private final class CellBoxes {
        var fills: [LayoutBox] = []
        var texts: [LayoutBox] = []
        var edges: [LayoutBox] = []
        var seen = Set<PlacedRect>()

        func edge(_ rect: PlacedRect) {
            if seen.insert(rect).inserted { edges.append(.rect(rect)) }
        }

        // Fills go under the text and borders over it; a shared edge is drawn once.
        func addTo(_ boxes: inout [LayoutBox]) {
            boxes.append(contentsOf: fills)
            boxes.append(contentsOf: texts)
            boxes.append(contentsOf: edges)
        }
    }

    // A piece of a cell: its fill, its lines from slot `from` up to `to`, then the borders of the sides it shows. The top
    // border belongs to the first piece of a row and the bottom one to the last.
    private static func emitCell(_ boxes: CellBoxes, _ cell: CellLines, _ originX: Double, _ y: Double, _ height: Double,
                                 _ from: Int, _ to: Int, _ first: Bool, _ last: Bool) {
        let source = cell.source
        let x0 = originX + cell.x, x1 = x0 + cell.width, y1 = y + height
        if let fill = source.fill { boxes.fills.append(.rect(PlacedRect(x: x0, y: y, width: cell.width, height: height, color: fill))) }

        var cursor = y + (from == 0 ? source.marginTop : 0)
        var content = 0.0
        for k in from..<to { content += cell.slots[k].height }
        if first && last && source.vAlign != .top {
            let free = height - source.marginTop - source.marginBottom - content
            if free > 0 { cursor += source.vAlign == .center ? free / 2 : free }
        }
        for k in from..<to {
            emitLine(&boxes.texts, cell.slots[k].line, x0 + source.marginLeft, cursor + cell.slots[k].lead)
            cursor += cell.slots[k].height
        }

        if first, let top = source.top {
            boxes.edge(PlacedRect(x: x0 - top.width / 2, y: y - top.width / 2, width: cell.width + top.width, height: top.width, color: top.color))
        }
        if last, let bottom = source.bottom {
            boxes.edge(PlacedRect(x: x0 - bottom.width / 2, y: y1 - bottom.width / 2, width: cell.width + bottom.width, height: bottom.width, color: bottom.color))
        }
        if let left = source.left {
            boxes.edge(PlacedRect(x: x0 - left.width / 2, y: y - left.width / 2, width: left.width, height: height + left.width, color: left.color))
        }
        if let right = source.right {
            boxes.edge(PlacedRect(x: x1 - right.width / 2, y: y - right.width / 2, width: right.width, height: height + right.width, color: right.color))
        }
    }
}
