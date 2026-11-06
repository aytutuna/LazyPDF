import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportFlow.cs: the line cells that sit on one row of the page, the paragraphs
// the rows join into, and the lists and tables read out of them. The C# regular expressions are matched by hand:
// NumberOnly is ^[0-9]{1,3}[.)]$ and NumberThenText is ^[0-9]{1,3}[.)]\s+(?=\S).

final class ExRow: Hashable {
    var cells: [ExLine] = []

    static func == (a: ExRow, b: ExRow) -> Bool { a === b }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    var before: TextBreak { cells[0].before }
    var left: Double { cells.map { $0.left }.min() ?? 0 }
    var right: Double { cells.map { $0.right }.max() ?? 0 }
    var top: Double { cells.map { $0.top }.min() ?? 0 }
    var bottom: Double { cells.map { $0.bottom }.max() ?? 0 }

    // The first of the cells with the longest text.
    var size: Double {
        var best = cells[0]
        var length = best.text.utf16.count
        for cell in cells.dropFirst() {
            let n = cell.text.utf16.count
            if n > length {
                best = cell
                length = n
            }
        }
        return best.size
    }

    var allBold: Bool { cells.allSatisfy { $0.allBold } }
    var text: String { cells.map { $0.text }.joined(separator: "\t") }
    var box: DisplayRect { DisplayRect(left, top, right - left, bottom - top) }

    func runs() -> [ExportRun] {
        var runs: [ExportRun] = []
        for cell in cells {
            if !runs.isEmpty { runs.append(ExportRun("\t", false, false, cell.size)) }
            runs += cell.runs
        }
        return runs
    }
}

/// A paragraph, heading candidate or list item while the lines are still being joined.
final class ExPara: Hashable {
    var runs: [ExportRun]
    var last: ExRow
    let size: Double
    let allBold: Bool
    let left: Double
    var right: Double
    let top: Double
    var bottom: Double
    var lines = 1
    var heading = 0

    /// For an item of a list: whether it is numbered, its number, and where its marker stood.
    let item: (ordered: Bool, number: Int, markerLeft: Double)?

    init(runs: [ExportRun], last: ExRow, size: Double, allBold: Bool, left: Double, right: Double, top: Double, bottom: Double,
         item: (ordered: Bool, number: Int, markerLeft: Double)?) {
        self.runs = runs
        self.last = last
        self.size = size
        self.allBold = allBold
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
        self.item = item
    }

    static func == (a: ExPara, b: ExPara) -> Bool { a === b }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    var text: String { runs.map { $0.text }.joined() }
    var box: DisplayRect { DisplayRect(left, top, max(0, right - left), max(0, bottom - top)) }
}

enum ExportFlow {
    private static let maxProbe = 256
    private static let maxBlankFactor = 4
    private static let bullets = Set("•◦▪▫●○■□‣⁃∙·▸►▶➢➤✓✔◆◇–—-*".unicodeScalars)

    private static func isBullet(_ c: Unicode.Scalar) -> Bool { bullets.contains(c) }

    // [0-9]{1,3} then . or ), as far as `scalars` goes; the count of digits, or 0 when the text does not start so.
    private static func numberLength(_ scalars: [Unicode.Scalar]) -> Int {
        var digits = 0
        while digits < scalars.count && digits < 3 && ExportChar.isAsciiDigit(scalars[digits]) { digits += 1 }
        guard digits > 0, digits < scalars.count, scalars[digits] == "." || scalars[digits] == ")" else { return 0 }
        return digits + 1
    }

    private static func isNumberOnly(_ scalars: [Unicode.Scalar]) -> Bool {
        let n = numberLength(scalars)
        return n > 0 && n == scalars.count
    }

    // The length of ^[0-9]{1,3}[.)]\s+(?=\S), or 0 when it does not match.
    private static func numberThenText(_ scalars: [Unicode.Scalar]) -> Int {
        let n = numberLength(scalars)
        if n == 0 { return 0 }
        var at = n
        while at < scalars.count && scalars[at].properties.isWhitespace { at += 1 }
        return at > n && at < scalars.count ? at : 0
    }

    static func isMarker(_ text: String) -> Bool {
        // A marker is one bullet or at most four characters of number.
        if text.utf8.count > 12 { return false }
        let scalars = Array(text.unicodeScalars)
        if text.utf16.count == 1, let c = scalars.first, isBullet(c) { return true }
        return isNumberOnly(scalars)
    }

    private static func lowerBound(_ values: [Double], _ target: Double) -> Int {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) >> 1
            if values[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// A bullet or number drawn apart from its text, which the text layer may have put in a column of its own, goes back
    /// in front of the text on its row. The marker's place in the order is dropped. A line takes one marker.
    static func joinMarkers(_ lines: inout [ExLine?]) {
        var markers: [Int] = []
        var candidates: [Int] = []
        for i in 0..<lines.count {
            guard let line = lines[i] else { continue }
            if isMarker(line.text) { markers.append(i) } else { candidates.append(i) }
        }
        // Looked up by height, a bounded number at a time, so a page of bare glyphs stays linear.
        let centers = lines.map { $0?.centerY ?? 0 }
        candidates = ExportSort.stable(candidates) { ExportSort.before(centers[$0], centers[$1]) }
        let heights = candidates.map { centers[$0] }
        var joined = Set<Int>()
        for i in markers {
            guard let marker = lines[i] else { continue }
            let reach = 0.5 * marker.size
            var k = lowerBound(heights, marker.centerY - reach)
            var at = -1
            var probes = 0
            while k < heights.count && heights[k] <= marker.centerY + reach && probes < maxProbe {
                let j = candidates[k]
                k += 1
                probes += 1
                guard let l = lines[j] else { continue }
                if joined.contains(j) || (at >= 0 && j > at) { continue }
                if l.left > marker.right - 0.1 * marker.size && l.left - marker.right < 3 * marker.size { at = j }
            }
            guard at >= 0, let text = lines[at], var first = marker.runs.first else { continue }
            first.text = marker.text + " "
            lines[at] = ExLine(
                box: DisplayRect(marker.left, min(marker.top, text.top), text.right - marker.left,
                                 max(marker.bottom, text.bottom) - min(marker.top, text.top)),
                runs: [first] + text.runs,
                size: text.size,
                allBold: text.allBold,
                before: text.before,
                block: text.block,
                isArtifact: text.isArtifact)
            joined.insert(at)
            lines[i] = nil
        }
    }

    static func rows(_ lines: [ExLine]) -> [ExRow] {
        var rows: [ExRow] = []
        for line in lines {
            if rows.isEmpty || line.before != .tab { rows.append(ExRow()) }
            rows[rows.count - 1].cells.append(line)
        }
        return rows
    }

    /// A block the text layer found to be a table, as cells under columns; nil when it has fewer than two columns.
    static func aligned(_ rows: [ExRow]) -> ExportTable? {
        if rows.count < 2 { return nil }
        let even = rows.allSatisfy { $0.cells.count == rows[0].cells.count }
        var spans: [(l: Double, r: Double)] = []
        if !even {
            // Cells whose extents overlap sit in one column.
            let all = rows.flatMap { $0.cells }
            for cell in ExportSort.stable(all, { ExportSort.before($0.left, $1.left) }) {
                if let last = spans.last, cell.left <= last.r + 0.5 {
                    spans[spans.count - 1] = (last.l, max(last.r, cell.right))
                } else {
                    spans.append((cell.left, cell.right))
                }
            }
        }
        let columns = even ? rows[0].cells.count : spans.count
        if columns < 2 { return nil }
        // Staggered text makes a column of its own for nearly every cell, and the blanks are not in the Analyze budget.
        if !even && columns * rows.count > maxBlankFactor * rows.reduce(0, { $0 + $1.cells.count }) { return nil }

        var body: [[String]] = []
        for row in rows {
            var cells = [String](repeating: "", count: columns)
            for i in 0..<row.cells.count {
                let cell = row.cells[i]
                let middle = (cell.left + cell.right) / 2
                var c = even ? i : (spans.firstIndex { middle <= $0.r + 0.25 } ?? -1)
                if c < 0 { c = columns - 1 }
                cells[c] = cells[c].isEmpty ? cell.text : cells[c] + " " + cell.text
            }
            body.append(cells)
        }
        let left = rows.map { $0.left }.min() ?? 0, top = rows.map { $0.top }.min() ?? 0
        let right = rows.map { $0.right }.max() ?? 0, bottom = rows.map { $0.bottom }.max() ?? 0
        return ExportTable(DisplayRect(left, top, right - left, bottom - top), body, nil, false)
    }

    static func paragraphs(_ rows: [ExRow]) -> [ExPara] {
        var paragraphs: [ExPara] = []
        if rows.isEmpty { return paragraphs }
        let blockLeft = rows.map { $0.left }.min() ?? 0, blockRight = rows.map { $0.right }.max() ?? 0
        var steps: [Double] = []
        for i in 1..<max(1, rows.count) {
            let d = rows[i].top - rows[i - 1].top
            if d > 0 { steps.append(d) }
        }
        steps.sort()
        let pitch = steps.count >= 2 ? steps[steps.count / 2] : 0
        var current: ExPara?
        for row in rows {
            if let found = item(row) {
                paragraphs.append(found)
                current = found
                continue
            }
            if let p = current, continues(p, row, blockLeft, blockRight, pitch) {
                append(p, row)
                continue
            }
            let made = make(row, row.runs(), nil)
            paragraphs.append(made)
            current = made
        }
        return paragraphs
    }

    private static func make(_ row: ExRow, _ runs: [ExportRun], _ item: (ordered: Bool, number: Int, markerLeft: Double)?) -> ExPara {
        ExPara(runs: runs, last: row, size: row.size, allBold: row.allBold, left: row.left, right: row.right, top: row.top, bottom: row.bottom, item: item)
    }

    // A step well over the usual line step, with a gap, is a paragraph break; double-spaced text has no such jump.
    private static func continues(_ p: ExPara, _ row: ExRow, _ blockLeft: Double, _ blockRight: Double, _ pitch: Double) -> Bool {
        if row.before != .line { return false }
        let prev = p.last
        let size = prev.size
        if abs(row.size - size) > 0.12 * size { return false }
        let gap = row.top - prev.bottom
        if pitch > 0 ? row.top - prev.top > 1.4 * pitch && gap > 0.2 * size : gap > 0.4 * size { return false }
        if p.lines == 1 && p.allBold != row.allBold { return false }
        if let item = p.item, row.left < item.markerLeft + 0.3 * size { return false }
        if p.item == nil && row.left - blockLeft > 0.8 * size && prev.left - blockLeft <= 0.3 * size { return false }
        let shortBy = blockRight - prev.right
        return shortBy <= max(0.25 * (blockRight - blockLeft), 3 * size)
    }

    private static func append(_ p: ExPara, _ row: ExRow) {
        let next = row.runs()
        guard let tailRun = p.runs.last else { return }
        let tail = Array(tailRun.text.unicodeScalars), head = next.first.map { Array($0.text.unicodeScalars) } ?? []
        let letters = tail.count >= 2 && ExportChar.isLetter(tail[tail.count - 2]) && !head.isEmpty && ExportChar.isLetter(head[0])
        let last = tail.last
        if letters && last == "\u{00AD}" {
            p.runs[p.runs.count - 1].text = String(String.UnicodeScalarView(tail.dropLast()))
        } else if letters && last == "-" && ExportChar.isLower(head[0]) {
            p.runs[p.runs.count - 1].text = String(String.UnicodeScalarView(tail.dropLast()))
        } else if !(letters && last == "-") {
            p.runs[p.runs.count - 1].text = tailRun.text + " "
        }
        p.runs += next
        p.last = row
        p.lines += 1
        p.right = max(p.right, row.right)
        p.bottom = max(p.bottom, row.bottom)
    }

    private static func item(_ row: ExRow) -> ExPara? {
        let first = Array(row.cells[0].text.unicodeScalars)
        if row.cells.count >= 2 && !first.isEmpty && (first.count == 1 && isBullet(first[0]) || isNumberOnly(first)) {
            let rest = ExRow()
            rest.cells = Array(row.cells.dropFirst())
            return make(row, rest.runs(), marker(first, row))
        }
        // first.Length >= 3 in UTF-16 units: the bullet and the white space are one unit each.
        if first.count >= 3 && isBullet(first[0]) && first[1].properties.isWhitespace {
            return make(row, strip(row.runs(), 1), marker([first[0]], row))
        }
        let n = numberThenText(first)
        if n > 0 {
            return make(row, strip(row.runs(), n), marker(Array(ExportTrim.both(String(String.UnicodeScalarView(first[0..<n]))).unicodeScalars), row))
        }
        return nil
    }

    private static func marker(_ marker: [Unicode.Scalar], _ row: ExRow) -> (ordered: Bool, number: Int, markerLeft: Double) {
        guard let first = marker.first, ExportChar.isAsciiDigit(first) else { return (false, 0, row.left) }
        var digits = 0
        for c in marker where ExportChar.isAsciiDigit(c) { digits = digits * 10 + Int(c.value - 0x30) }
        return (true, digits, row.left)
    }

    private static func strip(_ runs: [ExportRun], _ count: Int) -> [ExportRun] {
        var runs = runs
        var count = count
        while count > 0 && !runs.isEmpty {
            let text = Array(runs[0].text.unicodeScalars)
            if text.count <= count {
                count -= text.count
                runs.removeFirst()
            } else {
                runs[0].text = ExportTrim.start(String(String.UnicodeScalarView(text[count...])))
                count = 0
            }
        }
        if !runs.isEmpty { runs[0].text = ExportTrim.start(runs[0].text) }
        return runs
    }

    /// Adjacent runs in one style become one.
    static func merge(_ runs: [ExportRun]) -> [ExportRun] {
        var merged: [ExportRun] = []
        for run in runs {
            if run.text.isEmpty { continue }
            if let last = merged.last, last.bold == run.bold, last.italic == run.italic, abs(last.size - run.size) <= 0.6 {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}
