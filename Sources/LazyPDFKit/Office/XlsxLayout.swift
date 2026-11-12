import Foundation

// Twin of windows/LazyPDF.Core/Office/Xlsx/XlsxLayout.cs.

/// Sets the sheets of a workbook on pages as Excel prints them: the page setup picks the paper, margins, scale and breaks, a
/// grid of cells is cut into pages by the widths and heights of its columns and rows, and every page gets its cells, gridlines,
/// headings and header and footer. Page numbers run on through the workbook.
final class XlsxLayout {
    private static let pad = 2.0
    private static let vPad = 0.75
    private static let indentStep = 7.5
    private static let tolerance = 0.01
    private static let minArea = 36.0
    private static let maxBoxes = 4_000_000
    // Past this many boxes dashed borders are drawn solid.
    private static let dashBudget = 500_000
    private static let mergeBudget = 4_000_000
    private static let stride = XlsxLimits.maxColumn + 1
    private static let wide = 1e7

    private struct Band {
        let from: Int
        let to: Int
        let repeats: Bool
    }

    private struct Titles {
        let ids: [Int]
        let sizes: [Double]
        let last: Int
        let total: Double
    }

    private final class Plan {
        let sheet: XlsxSheet
        var rows: [Int: XlsxRow] = [:]
        var columnWidth = [Double](repeating: 0, count: XlsxLimits.maxColumn + 2)
        var rowHeight: [Int: Double] = [:]
        var anchors: [Int: XlsxRange] = [:]
        var covered: Set<Int> = []

        init(_ sheet: XlsxSheet) { self.sheet = sheet }

        func heightOf(_ row: Int) -> Double { rowHeight[row] ?? sheet.defaultRowHeight }
    }

    private final class Pending {
        let sheet: XlsxSheet
        let number: Int
        let indexInSheet: Int
        let width: Double
        let height: Double
        let scale: Double
        var boxes: [LayoutBox]

        init(sheet: XlsxSheet, number: Int, indexInSheet: Int, width: Double, height: Double, scale: Double, boxes: [LayoutBox]) {
            self.sheet = sheet
            self.number = number
            self.indexInSheet = indexInSheet
            self.width = width
            self.height = height
            self.scale = scale
            self.boxes = boxes
        }
    }

    private struct Item {
        let cell: XlsxCell
        let rowId: Int
        let row: Int
        let column: Int
        let x: Double
        let y: Double
        let w: Double
        let h: Double
        let merge: XlsxRange?
    }

    private struct PageGeometry {
        let paperWidth: Double
        let paperHeight: Double
        let scale: Double
        let headingWidth: Double
        let headingHeight: Double
    }

    private let book: XlsxWorkbook
    private let fonts: LayoutFonts
    private let now: Date
    private let file: String
    private var pages: [Pending] = []
    private var boxCount = 0
    private var number = 1

    private init(_ book: XlsxWorkbook, _ fonts: LayoutFonts, _ now: Date, _ file: String) {
        self.book = book
        self.fonts = fonts
        self.now = now
        self.file = file
    }

    /// Throws `PdfReadException` when there is nothing to print, the paper leaves no room, or the workbook runs to too many pages or boxes.
    static func run(_ book: XlsxWorkbook, _ fonts: LayoutFonts, _ now: Date, _ fileName: String) throws -> LayoutResult {
        let layout = XlsxLayout(book, fonts, now, fileName)
        for sheet in book.sheets { try layout.layoutSheet(sheet) }
        if layout.pages.isEmpty { throw PdfReadException(.unsupported, "The workbook has nothing to print.") }
        return try layout.finish()
    }

    // Paper

    private static func paper(_ s: XlsxPageSetup) -> (width: Double, height: Double) {
        let size: (Double, Double)
        switch s.paper {
        case 3, 4: size = (792.0, 1224.0)
        case 5: size = (612.0, 1008.0)
        case 6: size = (396.0, 612.0)
        case 7: size = (522.0, 756.0)
        case 8: size = (841.89, 1190.55)
        case 9, 10: size = (595.28, 841.89)
        case 11: size = (419.53, 595.28)
        case 12: size = (728.5, 1031.81)
        case 13: size = (515.91, 728.5)
        case 14: size = (612.0, 936.0)
        case 15: size = (609.45, 779.53)
        case 66: size = (1190.55, 1683.78)
        case 70: size = (297.64, 419.53)
        default: size = (612.0, 792.0)
        }
        return s.landscape ? (size.1, size.0) : (size.0, size.1)
    }

    // Sheet plan

    private static func lowerBound<T>(_ list: [T], _ key: (T) -> Int, _ value: Int) -> Int {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if key(list[mid]) < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func cellAt(_ plan: Plan, _ row: Int, _ column: Int) -> XlsxCell? {
        guard let r = plan.rows[row] else { return nil }
        let at = lowerBound(r.cells, { $0.column }, column)
        return at < r.cells.count && r.cells[at].column == column ? r.cells[at] : nil
    }

    private func fontOf(_ cell: XlsxCell) -> XlsxFont {
        let styles = book.styles
        return cell.richFont ?? styles.fonts[min(styles.xf(cell.style).font, styles.fonts.count - 1)]
    }

    private func makePlan(_ sheet: XlsxSheet) throws -> Plan {
        let plan = Plan(sheet)
        for row in sheet.rows { plan.rows[row.index] = row }

        // The first run that names a column wins; "next" skips the columns that already have a width.
        var next = Array(0..<(XlsxLimits.maxColumn + 3))
        func find(_ start: Int) -> Int {
            var c = start
            while next[c] != c {
                next[c] = next[next[c]]
                c = next[c]
            }
            return c
        }
        for run in sheet.columns {
            var c = find(run.first)
            while c <= run.last {
                plan.columnWidth[c] = run.hidden ? 0 : run.width
                next[c] = c + 1
                c = find(c)
            }
        }
        for c in 1...XlsxLimits.maxColumn where find(c) == c { plan.columnWidth[c] = sheet.defaultColumnWidth }

        var budget = Self.mergeBudget
        for m in sheet.merges {
            let anchor = m.firstRow * Self.stride + m.firstColumn
            if plan.anchors[anchor] == nil { plan.anchors[anchor] = m }
            var i = Self.lowerBound(sheet.rows, { $0.index }, m.firstRow)
            while i < sheet.rows.count && sheet.rows[i].index <= m.lastRow && budget > 0 {
                let cells = sheet.rows[i].cells
                budget -= 1
                var k = Self.lowerBound(cells, { $0.column }, m.firstColumn)
                while k < cells.count && cells[k].column <= m.lastColumn && budget > 0 {
                    budget -= 1
                    let key = sheet.rows[i].index * Self.stride + cells[k].column
                    if key != anchor { plan.covered.insert(key) }
                    k += 1
                }
                i += 1
            }
        }

        for row in sheet.rows {
            try Task.checkCancellation()
            if row.hidden {
                plan.rowHeight[row.index] = 0
            } else if let height = row.height {
                plan.rowHeight[row.index] = height
            } else {
                plan.rowHeight[row.index] = try autoHeight(plan, row)
            }
        }
        return plan
    }

    private func pitch(_ font: XlsxFont) throws -> Double {
        var style: FontStyles = []
        if font.bold { style.insert(.bold) }
        if font.italic { style.insert(.italic) }
        guard let face = fonts.find(font.name, style) ?? fonts.find(OfficeFontSource.defaultFamily, style) else {
            throw InvalidOperationException(ExportText.noFont)
        }
        return (face.ascent + face.descent) * font.size + 1.5
    }

    // A row with no stated height grows with the tallest font in it and with the lines a wrapped text takes.
    private func autoHeight(_ plan: Plan, _ row: XlsxRow) throws -> Double {
        var height = plan.sheet.defaultRowHeight
        for cell in row.cells {
            if cell.kind == .blank { continue }
            let font = fontOf(cell)
            var pitch = try self.pitch(font)
            let key = row.index * Self.stride + cell.column
            let xf = book.styles.xf(cell.style)
            if xf.wrap && cell.kind == .text && !plan.covered.contains(key) && plan.anchors[key] == nil {
                let inner = plan.columnWidth[cell.column] - 2 * Self.pad
                if inner > 1 && !cell.text.isEmpty {
                    var total = 0.0
                    for line in try lines(cell.text, font, Self.align(cell, xf), inner) { total += line.height }
                    pitch = total + 1.5
                }
            }
            height = max(height, pitch)
        }
        return min(height, 409.5)
    }

    private static func align(_ cell: XlsxCell, _ xf: XlsxXf) -> LayoutAlign {
        switch horizontal(cell, xf) {
        case .right: return .right
        case .center, .centerContinuous, .distributed: return .center
        case .justify: return .justify
        default: return .left
        }
    }

    private static func horizontal(_ cell: XlsxCell, _ xf: XlsxXf) -> XlsxHorizontal {
        if xf.horizontal != .general { return xf.horizontal }
        switch cell.kind {
        case .number: return .right
        case .bool, .error: return .center
        default: return .left
        }
    }

    private static func runOf(_ font: XlsxFont, _ text: String, _ color: Int) -> LayoutRun {
        let run = LayoutRun()
        run.text = text
        run.family = font.name
        run.size = font.size
        run.bold = font.bold
        run.italic = font.italic
        run.underline = font.underline
        run.strike = font.strike
        run.color = color
        return run
    }

    private func lines(_ text: String, _ font: XlsxFont, _ align: LayoutAlign, _ width: Double, _ color: Int = 0) throws -> [LayoutLine] {
        let paragraph = LayoutParagraph()
        paragraph.runs = [Self.runOf(font, text, color)]
        paragraph.align = align
        return try ParagraphLayout.run(paragraph, fonts, width, Self.wide).lines
    }

    // Used range and areas

    private static func used(_ plan: Plan) -> XlsxRange? {
        var rows = 0, columns = 0
        for row in plan.sheet.rows where !row.cells.isEmpty {
            rows = row.index
            columns = max(columns, row.cells[row.cells.count - 1].column)
        }
        for m in plan.anchors.values where cellAt(plan, m.firstRow, m.firstColumn) != nil {
            rows = max(rows, m.lastRow)
            columns = max(columns, m.lastColumn)
        }
        return rows == 0 ? nil : XlsxRange(firstRow: 1, firstColumn: 1, lastRow: rows, lastColumn: columns)
    }

    private func layoutSheet(_ sheet: XlsxSheet) throws {
        let setup = sheet.setup
        let (paperWidth, paperHeight) = Self.paper(setup)
        if paperWidth - setup.left - setup.right < Self.minArea || paperHeight - setup.top - setup.bottom < Self.minArea {
            throw PdfReadException(.unsupported, "The page size or margins leave no room for text.")
        }
        let plan = try makePlan(sheet)
        let stated = !sheet.printArea.isEmpty
        var areas: [XlsxRange] = []
        if stated {
            areas = sheet.printArea
        } else if let used = Self.used(plan) {
            areas.append(used)
        }
        if areas.isEmpty { return }

        if let first = setup.firstPageNumber { number = first }
        var index = 0
        for area in areas { try layoutArea(plan, area, stated, paperWidth, paperHeight, &index) }
    }

    private static func strip(_ first: Int, _ last: Int, _ size: (Int) -> Double) -> (ids: [Int], sizes: [Double]) {
        var ids: [Int] = []
        var sizes: [Double] = []
        if first > last { return (ids, sizes) }
        for i in first...last {
            let s = size(i)
            if s <= 0 { continue }
            ids.append(i)
            sizes.append(s)
        }
        return (ids, sizes)
    }

    private static func titlesOf(_ span: (first: Int, last: Int)?, _ size: (Int) -> Double) -> Titles? {
        guard let span else { return nil }
        var ids: [Int] = []
        var sizes: [Double] = []
        var total = 0.0
        if span.first <= span.last {
            for i in span.first...span.last {
                let s = size(i)
                if s <= 0 { continue }
                ids.append(i)
                sizes.append(s)
                total += s
            }
        }
        return ids.isEmpty ? nil : Titles(ids: ids, sizes: sizes, last: span.last, total: total)
    }

    private static func breakBetween(_ breaks: [Int], _ after: Int, _ before: Int) -> Bool {
        let at = lowerBound(breaks, { $0 }, after)
        return at < breaks.count && breaks[at] < before
    }

    // Cuts a run of rows or columns into pages of at most "capacity". A page holds at least one item; the titles are repeated on
    // the pages that start after them.
    private static func split(_ ids: [Int], _ sizes: [Double], _ capacity: Double, _ breaks: [Int], _ titles: Titles?) -> [Band] {
        var bands: [Band] = []
        var i = 0
        while i < ids.count {
            let repeats = titles != nil && ids[i] > titles!.last
            var used = repeats ? titles!.total : 0
            var j = i
            repeat {
                used += sizes[j]
                j += 1
            } while j < ids.count && !breakBetween(breaks, ids[j - 1], ids[j]) && used + sizes[j] <= capacity + tolerance
            bands.append(Band(from: i, to: j - 1, repeats: repeats))
            i = j
        }
        return bands
    }

    private static func tooManyPages() -> PdfReadException { PdfReadException(.unsupported, "The document has too many pages.") }

    private static func bandOf(_ bands: [Band], _ ids: [Int], _ id: Int) -> Int {
        var lo = 0, hi = bands.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if ids[bands[mid].from] <= id { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func layoutArea(_ plan: Plan, _ area: XlsxRange, _ stated: Bool, _ paperWidth: Double, _ paperHeight: Double, _ index: inout Int) throws {
        let sheet = plan.sheet
        let setup = sheet.setup
        let (rowIds, rowSizes) = Self.strip(area.firstRow, area.lastRow, plan.heightOf)
        let (columnIds, columnSizes) = Self.strip(area.firstColumn, area.lastColumn) { plan.columnWidth[$0] }
        if rowIds.isEmpty || columnIds.isEmpty { return }
        let rowTitles = Self.titlesOf(sheet.titleRows, plan.heightOf)
        let columnTitles = Self.titlesOf(sheet.titleColumns) { plan.columnWidth[$0] }

        let headingHeight = setup.headings ? sheet.defaultRowHeight : 0
        let headingWidth = setup.headings ? Double(max(2, String(rowIds[rowIds.count - 1]).count)) * Double(book.styles.maxDigitWidth) * 0.75 + 6 : 0
        let availableWidth = paperWidth - setup.left - setup.right, availableHeight = paperHeight - setup.top - setup.bottom

        let rowBreaks = setup.fitToPage ? [] : setup.rowBreaks
        let columnBreaks = setup.fitToPage ? [] : setup.columnBreaks
        func rowBands(_ scale: Int) -> [Band] { Self.split(rowIds, rowSizes, availableHeight * 100 / Double(scale) - headingHeight, rowBreaks, rowTitles) }
        func columnBands(_ scale: Int) -> [Band] { Self.split(columnIds, columnSizes, availableWidth * 100 / Double(scale) - headingWidth, columnBreaks, columnTitles) }

        var scale = setup.scale
        if setup.fitToPage {
            let wide = setup.fitToWidth, high = setup.fitToHeight
            var estimate = 100.0
            if wide > 0 {
                var total = 0.0
                for s in columnSizes { total += s }
                estimate = min(estimate, availableWidth * Double(wide) * 100 / (total + headingWidth))
            }
            if high > 0 {
                var total = 0.0
                for s in rowSizes { total += s }
                estimate = min(estimate, availableHeight * Double(high) * 100 / (total + headingHeight))
            }
            scale = min(max(Int(estimate.rounded(.down)), 10), 100)
            while scale > 10 && ((wide > 0 && columnBands(scale).count > wide) || (high > 0 && rowBands(scale).count > high)) { scale -= 1 }
        }
        let rowBandList = rowBands(scale)
        let columnBandList = columnBands(scale)

        var pairs: [(row: Int, column: Int)] = []
        if stated {
            for c in 0..<columnBandList.count {
                for r in 0..<rowBandList.count {
                    if pairs.count + pages.count >= Paginator.maxPages { throw Self.tooManyPages() }
                    pairs.append((r, c))
                }
            }
        } else {
            var marked: Set<Int> = []
            for row in sheet.rows {
                if row.index < rowIds[0] || row.index > rowIds[rowIds.count - 1] { continue }
                let r = Self.bandOf(rowBandList, rowIds, row.index)
                for cell in row.cells {
                    if cell.column < columnIds[0] || cell.column > columnIds[columnIds.count - 1] { continue }
                    marked.insert(r * columnBandList.count + Self.bandOf(columnBandList, columnIds, cell.column))
                }
            }
            for key in marked { pairs.append((key / columnBandList.count, key % columnBandList.count)) }
        }
        if setup.overThenDown {
            pairs.sort { $0.row != $1.row ? $0.row < $1.row : $0.column < $1.column }
        } else {
            pairs.sort { $0.column != $1.column ? $0.column < $1.column : $0.row < $1.row }
        }

        let geometry = PageGeometry(paperWidth: paperWidth, paperHeight: paperHeight, scale: Double(scale) / 100.0, headingWidth: headingWidth, headingHeight: headingHeight)
        for (r, c) in pairs {
            try Task.checkCancellation()
            if pages.count >= Paginator.maxPages { throw Self.tooManyPages() }
            var boxes: [LayoutBox] = []
            let spill = !stated && columnBandList[c].to == columnIds.count - 1 ? availableWidth * 100 / Double(scale) : 0
            guard let size = try build(plan, geometry, stated, spill, rowIds, rowSizes, columnIds, columnSizes, rowBandList[r], columnBandList[c], rowTitles, columnTitles, &boxes) else { continue }
            boxCount += boxes.count
            if boxCount > Self.maxBoxes { throw PdfReadException(.unsupported, "The workbook is too large to convert.") }
            pages.append(Pending(sheet: sheet, number: number, indexInSheet: index, width: paperWidth, height: paperHeight, scale: geometry.scale,
                                 boxes: Self.place(boxes, setup, geometry, size.width, size.height)))
            number += 1
            index += 1
        }
    }

    // The boxes of a page are built in sheet points from the top left of the content; place scales them and moves them to the margins.
    private static func place(_ boxes: [LayoutBox], _ setup: XlsxPageSetup, _ g: PageGeometry, _ width: Double, _ height: Double) -> [LayoutBox] {
        let k = g.scale
        var x = setup.left, y = setup.top
        if setup.centerHorizontally { x += max(0, (g.paperWidth - setup.left - setup.right - width * k) / 2) }
        if setup.centerVertically { y += max(0, (g.paperHeight - setup.top - setup.bottom - height * k) / 2) }
        return move(boxes, k, x, y)
    }

    private static func move(_ boxes: [LayoutBox], _ k: Double, _ x: Double, _ y: Double) -> [LayoutBox] {
        var moved: [LayoutBox] = []
        moved.reserveCapacity(boxes.count)
        for box in boxes {
            switch box {
            case .text(let t):
                moved.append(.text(PlacedText(x: x + t.x * k, baseline: y + t.baseline * k, text: t.text, family: t.family, style: t.style,
                                              size: t.size * k, color: t.color, spaceExtra: t.spaceExtra * k)))
            case .rect(let r):
                moved.append(.rect(PlacedRect(x: x + r.x * k, y: y + r.y * k, width: r.width * k, height: r.height * k, color: r.color)))
            case .image, .path:
                break
            }
        }
        return moved
    }

    // One page

    private func build(
        _ plan: Plan, _ g: PageGeometry, _ stated: Bool, _ spill: Double, _ rowIds: [Int], _ rowSizes: [Double], _ columnIds: [Int], _ columnSizes: [Double],
        _ rowBand: Band, _ columnBand: Band, _ rowTitles: Titles?, _ columnTitles: Titles?, _ boxes: inout [LayoutBox]
    ) throws -> (width: Double, height: Double)? {
        let setup = plan.sheet.setup
        var rows: [Int] = [], heights: [Double] = [], columns: [Int] = [], widths: [Double] = []
        if rowBand.repeats, let titles = rowTitles {
            rows += titles.ids
            heights += titles.sizes
        }
        let bodyRow = rows.count
        for i in rowBand.from...rowBand.to {
            rows.append(rowIds[i])
            heights.append(rowSizes[i])
        }
        if columnBand.repeats, let titles = columnTitles {
            columns += titles.ids
            widths += titles.sizes
        }
        let bodyColumn = columns.count
        for i in columnBand.from...columnBand.to {
            columns.append(columnIds[i])
            widths.append(columnSizes[i])
        }

        var top = [Double](repeating: 0, count: rows.count + 1)
        var left = [Double](repeating: 0, count: columns.count + 1)
        top[0] = g.headingHeight
        for i in 0..<rows.count { top[i + 1] = top[i] + heights[i] }
        left[0] = g.headingWidth
        for i in 0..<columns.count { left[i + 1] = left[i] + widths[i] }
        let width = left[left.count - 1], height = top[top.count - 1]
        var columnAt: [Int: Int] = [:]
        for i in 0..<columns.count { columnAt[columns[i]] = i }

        if setup.gridlines {
            for i in 0..<top.count { boxes.append(.rect(PlacedRect(x: g.headingWidth, y: top[i] - 0.25, width: width - g.headingWidth, height: 0.5, color: 0x808080))) }
            for i in 0..<left.count { boxes.append(.rect(PlacedRect(x: left[i] - 0.25, y: g.headingHeight, width: 0.5, height: height - g.headingHeight, color: 0x808080))) }
        }

        var items: [Item] = []
        var content = false
        for i in 0..<rows.count {
            guard let row = plan.rows[rows[i]] else { continue }
            for cell in row.cells {
                guard let j = columnAt[cell.column] else { continue }
                let key = row.index * Self.stride + cell.column
                if plan.covered.contains(key) { continue }
                var lastRow = i, lastColumn = j
                var merge: XlsxRange?
                if let m = plan.anchors[key] {
                    merge = m
                    lastRow = max(i, Self.lastAtMost(rows, m.lastRow))
                    lastColumn = max(j, Self.lastAtMost(columns, m.lastColumn))
                }
                let item = Item(cell: cell, rowId: row.index, row: i, column: j, x: left[j], y: top[i], w: left[lastColumn + 1] - left[j], h: top[lastRow + 1] - top[i], merge: merge)
                items.append(item)
                if i >= bodyRow && j >= bodyColumn { content = true }
                let xf = book.styles.xf(cell.style)
                if xf.fill < book.styles.fills.count, let fill = book.styles.fills[xf.fill].color {
                    boxes.append(.rect(PlacedRect(x: item.x, y: item.y, width: item.w, height: item.h, color: fill)))
                }
            }
        }
        if !content && !stated { return nil }

        for item in items { try text(plan, item, rows, columns, left, spill, &boxes) }
        for item in items { border(plan, item, rows, columns, &boxes) }
        if setup.headings { try headings(g, rows, columns, top, left, &boxes) }
        return (width, height)
    }

    private static func lastAtMost(_ ids: [Int], _ limit: Int) -> Int {
        var lo = 0, hi = ids.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if ids[mid] <= limit {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }

    // Text

    private func empty(_ plan: Plan, _ row: XlsxRow, _ column: Int) -> Bool {
        let key = row.index * Self.stride + column
        if plan.covered.contains(key) || plan.anchors[key] != nil { return false }
        guard let cell = Self.cellAt(plan, row.index, column) else { return true }
        return cell.kind == .blank
    }

    // How far text may run from a cell: through the empty cells next to it on the page.
    private func reach(_ plan: Plan, _ row: XlsxRow, _ columns: [Int], _ left: [Double], _ j: Int, _ step: Int, _ spill: Double) -> Double {
        var at = j
        while true {
            let next = at + step
            if next < 0 || next >= columns.count { break }
            var adjacent = true
            var id = min(columns[at], columns[next]) + 1
            while id < max(columns[at], columns[next]) {
                if plan.columnWidth[id] > 0 { adjacent = false }
                id += 1
            }
            if !adjacent || !empty(plan, row, columns[next]) { break }
            at = next
        }
        if step < 0 { return left[at] }
        var x = left[at + 1]
        // On the last page of a sheet without a print area, text may run on past the columns that are printed, up to the margin.
        if spill > 0 && at == columns.count - 1 {
            var id = columns[at] + 1
            while id <= XlsxLimits.maxColumn {
                let w = plan.columnWidth[id]
                id += 1
                if w <= 0 { continue }
                if !empty(plan, row, id - 1) { break }
                if x + w > spill { return max(x, spill) }
                x += w
            }
        }
        return x
    }

    private func text(_ plan: Plan, _ item: Item, _ rows: [Int], _ columns: [Int], _ left: [Double], _ spill: Double, _ boxes: inout [LayoutBox]) throws {
        let cell = item.cell
        if cell.kind == .blank || cell.text.isEmpty { return }
        let xf = book.styles.xf(cell.style)
        let font = fontOf(cell)
        let color = cell.color ?? font.color ?? 0
        let horizontal = Self.horizontal(cell, xf)
        var limitLeft = item.x + Self.pad, limitRight = item.x + item.w - Self.pad
        var span = item.w
        let wrap = xf.wrap && cell.kind == .text
        if !wrap && cell.kind == .text && item.merge == nil, let row = plan.rows[rows[item.row]] {
            // Text spills out of its cell on the side or sides its alignment leaves free.
            if horizontal == .left || horizontal == .fill || horizontal == .justify {
                limitRight = max(limitRight, reach(plan, row, columns, left, item.column, 1, spill) - Self.pad)
            } else if horizontal == .right {
                limitLeft = min(limitLeft, reach(plan, row, columns, left, item.column, -1, spill) + Self.pad)
            } else if horizontal == .centerContinuous {
                // Center Across Selection centers over the empty cells to its right, as one wide cell.
                span = reach(plan, row, columns, left, item.column, 1, spill) - item.x
                limitRight = item.x + span - Self.pad
            } else {
                let extra = min(reach(plan, row, columns, left, item.column, 1, spill) - (item.x + item.w), item.x - reach(plan, row, columns, left, item.column, -1, spill))
                limitLeft -= extra
                limitRight += extra
            }
        }
        let indent = Double(xf.indent) * Self.indentStep
        let align = Self.align(cell, xf)
        if wrap {
            try wrapped(cell.text, font, color, align, xf.vertical, indent, item, &boxes)
        } else {
            try single(cell.text, font, color, horizontal, xf.vertical, indent, cell.kind == .number, item.x, item.y, span, item.h, limitLeft, limitRight, &boxes)
        }
    }

    private static func topOf(_ vertical: XlsxVertical, _ y: Double, _ h: Double, _ text: Double) -> Double {
        switch vertical {
        case .top, .justify, .distributed: return y + vPad
        case .center: return y + (h - text) / 2
        case .bottom: return y + h - vPad - text
        }
    }

    // A carriage return alone counts as a line end, as the C# engine reads it.
    private static func lineEnds(_ text: String, _ replacement: UInt16) -> String {
        let units = Array(text.utf16)
        var out: [UInt16] = []
        var i = 0
        while i < units.count {
            if units[i] == 0x0D {
                out.append(replacement)
                if i + 1 < units.count && units[i + 1] == 0x0A { i += 1 }
            } else if units[i] == 0x0A {
                out.append(replacement)
            } else {
                out.append(units[i])
            }
            i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }

    private func wrapped(_ text: String, _ font: XlsxFont, _ color: Int, _ align: LayoutAlign, _ vertical: XlsxVertical, _ indent: Double, _ item: Item, _ boxes: inout [LayoutBox]) throws {
        let shift = align == .left ? indent : 0
        let inner = item.w - 2 * Self.pad - (align == .left || align == .right ? indent : 0)
        if inner < 1 { return }
        let paragraph = LayoutParagraph()
        paragraph.runs = [Self.runOf(font, Self.lineEnds(text, 0x0A), color)]
        paragraph.align = align
        let lines = try ParagraphLayout.run(paragraph, fonts, inner, Self.wide).lines
        var total = 0.0
        for line in lines { total += line.height }
        var y = Self.topOf(vertical, item.y, item.h, total)
        for line in lines {
            if y >= item.y - 0.5 && y + line.height <= item.y + item.h + line.height * 0.25 { Paginator.emitLine(&boxes, line, item.x + Self.pad + shift, y) }
            y += line.height
        }
    }

    private func single(
        _ source: String, _ font: XlsxFont, _ color: Int, _ horizontal: XlsxHorizontal, _ vertical: XlsxVertical, _ indent: Double, _ number: Bool,
        _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ limitLeft: Double, _ limitRight: Double, _ boxes: inout [LayoutBox]
    ) throws {
        let text = Self.lineEnds(source, 0x20)
        var line = try lines(text, font, .left, Self.wide, color)[0]
        var width = Self.ink(line)
        let room = w - 2 * Self.pad
        if number && width > room + Self.tolerance {
            let hash = Self.ink(try lines("#", font, .left, Self.wide)[0])
            line = try lines(String(repeating: "#", count: max(1, Int((room / hash).rounded(.down)))), font, .left, Self.wide, color)[0]
            width = Self.ink(line)
        }
        let origin: Double
        switch horizontal {
        case .right: origin = x + w - Self.pad - indent - width
        case .center, .centerContinuous, .distributed: origin = x + (w - width) / 2
        default: origin = x + Self.pad + indent
        }
        line.atoms.removeAll { origin + $0.x < limitLeft - Self.tolerance || origin + $0.x + $0.width > limitRight + Self.tolerance }
        if line.atoms.allSatisfy({ $0.isBlank }) { return }
        let top = Self.topOf(vertical, y, h, line.height)
        if top < y - 0.5 || top + line.height > y + h + line.height * 0.25 { return }
        Paginator.emitLine(&boxes, line, origin, top)
    }

    private static func ink(_ line: LayoutLine) -> Double {
        guard let ink = line.atoms.lastIndex(where: { !$0.isBlank }) else { return 0 }
        return line.atoms[ink].x + line.atoms[ink].width
    }

    // Borders

    private static func look(_ style: String) -> (width: Double, twin: Bool, pattern: Int) {
        switch style {
        case "hair": return (0.5, false, 0)
        case "thin": return (0.75, false, 0)
        case "medium": return (1.5, false, 0)
        case "thick": return (2.25, false, 0)
        case "double": return (0.75, true, 0)
        case "dotted": return (0.75, false, 2)
        case "dashed", "dashDot", "dashDotDot": return (0.75, false, 1)
        case "mediumDashed", "mediumDashDot", "mediumDashDotDot", "slantDashDot": return (1.5, false, 1)
        default: return (0.75, false, 0)
        }
    }

    private func edge(_ boxes: inout [LayoutBox], _ horizontal: Bool, _ at: Double, _ from: Double, _ to: Double, _ edge: XlsxBorderEdge) {
        let (width, twin, pattern) = Self.look(edge.style)
        let color = edge.color ?? 0
        let solid = pattern == 0 || boxes.count + boxCount > Self.dashBudget
        func line(_ offset: Double, _ w: Double) {
            let a = from - w / 2, b = to + w / 2
            let on = pattern == 1 ? width * 3 : width, off = pattern == 1 ? width * 1.5 : width
            func segment(_ start: Double, _ length: Double) {
                boxes.append(.rect(horizontal ? PlacedRect(x: start, y: at + offset - w / 2, width: length, height: w, color: color)
                                              : PlacedRect(x: at + offset - w / 2, y: start, width: w, height: length, color: color)))
            }
            if solid {
                segment(a, b - a)
                return
            }
            var p = a
            while p < b - Self.tolerance {
                segment(p, min(on, b - p))
                p += on + off
            }
        }
        if twin {
            line(-width, width)
            line(width, width)
        } else {
            line(0, width)
        }
    }

    private func border(_ plan: Plan, _ item: Item, _ rows: [Int], _ columns: [Int], _ boxes: inout [LayoutBox]) {
        guard let own = borderOf(item.cell) else { return }
        let right = item.x + item.w, bottom = item.y + item.h
        let row = item.rowId, column = item.cell.column
        var topEdge = own.top
        var leftEdge = own.left
        var rightEdge = own.right
        var bottomEdge = own.bottom
        if let m = item.merge {
            rightEdge = Self.cellAt(plan, m.firstRow, m.lastColumn).flatMap { borderOf($0)?.right }
            bottomEdge = Self.cellAt(plan, m.lastRow, m.firstColumn).flatMap { borderOf($0)?.bottom }
        }
        // A neighbour only hides the shared edge when it is printed right beside this cell on the same page.
        if leftEdge != nil, item.column > 0, columns[item.column - 1] == column - 1, let l = Self.cellAt(plan, row, column - 1), borderOf(l)?.right != nil { leftEdge = nil }
        if topEdge != nil, item.row > 0, rows[item.row - 1] == row - 1, let t = Self.cellAt(plan, row - 1, column), borderOf(t)?.bottom != nil { topEdge = nil }
        if let e = topEdge { edge(&boxes, true, item.y, item.x, right, e) }
        if let e = leftEdge { edge(&boxes, false, item.x, item.y, bottom, e) }
        if let e = rightEdge { edge(&boxes, false, right, item.y, bottom, e) }
        if let e = bottomEdge { edge(&boxes, true, bottom, item.x, right, e) }
    }

    private func borderOf(_ cell: XlsxCell) -> XlsxBorder? {
        let styles = book.styles
        let index = styles.xf(cell.style).border
        return index < styles.borders.count ? styles.borders[index] : nil
    }

    // Headings

    private static func columnName(_ column: Int) -> String {
        var letters = ""
        var c = column
        while c > 0 {
            letters = String(UnicodeScalar(UInt8(65 + (c - 1) % 26))) + letters
            c = (c - 1) / 26
        }
        return letters
    }

    private func headings(_ g: PageGeometry, _ rows: [Int], _ columns: [Int], _ top: [Double], _ left: [Double], _ boxes: inout [LayoutBox]) throws {
        let font = book.styles.fonts[0]
        let hair = XlsxBorderEdge(style: "hair", color: 0x808080)
        func box(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) throws {
            edge(&boxes, true, y, x, x + w, hair)
            edge(&boxes, true, y + h, x, x + w, hair)
            edge(&boxes, false, x, y, y + h, hair)
            edge(&boxes, false, x + w, y, y + h, hair)
            try single(text, font, 0, .center, .center, 0, false, x, y, w, h, x, x + w, &boxes)
        }
        for j in 0..<columns.count { try box(Self.columnName(columns[j]), left[j], 0, left[j + 1] - left[j], g.headingHeight) }
        for i in 0..<rows.count { try box(String(rows[i]), 0, top[i], g.headingWidth, top[i + 1] - top[i]) }
    }

    // Header and footer

    private func finish() throws -> LayoutResult {
        var result: [LayoutPage] = []
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let hour = parts.hour! % 12 == 0 ? 12 : parts.hour! % 12
        let date = "\(parts.month!)/\(parts.day!)/\(parts.year!)"
        let minute = parts.minute! < 10 ? "0\(parts.minute!)" : "\(parts.minute!)"
        let time = "\(hour):\(minute) \(parts.hour! < 12 ? "AM" : "PM")"
        for page in pages {
            try Task.checkCancellation()
            let setup = page.sheet.setup
            let context = HfContext(page: page.number, pages: pages.count, date: date, time: time, file: file, sheet: page.sheet.name)
            let first = setup.differentFirst && page.indexInSheet == 0
            let even = setup.differentOddEven && page.number % 2 == 0
            let header = first ? setup.firstHeader : even ? setup.evenHeader : setup.oddHeader
            let footer = first ? setup.firstFooter : even ? setup.evenFooter : setup.oddFooter
            try band(&page.boxes, header, context, setup, page, footer: false)
            try band(&page.boxes, footer, context, setup, page, footer: true)
            result.append(LayoutPage(width: page.width, height: page.height, boxes: page.boxes))
        }
        return LayoutResult(pages: result, skipped: book.skipped, missing: fonts.missing.sorted())
    }

    private func band(_ boxes: inout [LayoutBox], _ source: String, _ context: HfContext, _ setup: XlsxPageSetup, _ page: Pending, footer: Bool) throws {
        if source.isEmpty { return }
        let sections = XlsxHeaderFooter.parse(source, context)
        let font = book.styles.fonts[0]
        let k = setup.scaleWithDocument ? page.scale : 1
        let x = setup.alignWithMargins ? setup.left : 0
        let width = (setup.alignWithMargins ? page.width - setup.left - setup.right : page.width) / k

        var local: [LayoutBox] = []
        var block = 0.0
        for s in 0..<3 {
            var y = 0.0
            for line in sections[s] {
                var runs = line.map { r in
                    Self.runOf(XlsxFont(name: font.name, size: font.size, bold: font.bold || r.bold, italic: font.italic || r.italic,
                                        underline: font.underline, strike: font.strike, color: font.color), r.text, 0)
                }
                if runs.isEmpty { runs.append(Self.runOf(font, "", 0)) }
                let paragraph = LayoutParagraph()
                paragraph.runs = runs
                let laid = try ParagraphLayout.run(paragraph, fonts, Self.wide, Self.wide).lines[0]
                let w = Self.ink(laid)
                Paginator.emitLine(&local, laid, s == 0 ? 0 : s == 1 ? (width - w) / 2 : width - w, y)
                y += laid.height
            }
            block = max(block, y)
        }
        let top = footer ? page.height - setup.footer - block * k : setup.header
        boxes.append(contentsOf: Self.move(local, k, x, top))
    }
}
