import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportGrid.cs: finds tables from the horizontal and vertical lines of a page and
// fills their cells with the text inside.

/// A grid the page draws with lines, with the text lines that sit in it.
struct ExportRuled {
    let table: ExportTable
    let lines: [ExLine]
}

enum ExportGrid {
    private static let snap = 2.0
    private static let gap = 3.0
    private static let maxPairs = 4_000_000
    private static let maxCells = 20000

    static func find(_ rules: [ExportRule], _ lines: [ExLine]) -> [ExportRuled] {
        var found: [ExportRuled] = []
        let hs = merge(rules.filter { $0.horizontal })
        let vs = merge(rules.filter { !$0.horizontal })
        if hs.count < 2 || vs.count < 2 || hs.count * vs.count > maxPairs { return found }

        var parent = Array(0..<(hs.count + vs.count))
        func root(_ start: Int) -> Int {
            var i = start
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for h in 0..<hs.count {
            for v in 0..<vs.count {
                if vs[v].pos >= hs[h].from - snap && vs[v].pos <= hs[h].to + snap && hs[h].pos >= vs[v].from - snap && hs[h].pos <= vs[v].to + snap {
                    let a = root(h), b = root(hs.count + v)
                    parent[a] = b
                }
            }
        }

        // The groups in the order their first member comes.
        var order: [Int] = []
        var members: [Int: (h: [ExportRule], v: [ExportRule])] = [:]
        for i in 0..<(hs.count + vs.count) {
            let r = root(i)
            if members[r] == nil {
                members[r] = ([], [])
                order.append(r)
            }
            if i < hs.count { members[r]?.h.append(hs[i]) } else { members[r]?.v.append(vs[i - hs.count]) }
        }
        let groups = order.compactMap { members[$0] }.filter { $0.h.count >= 2 && $0.v.count >= 2 }

        // The smaller grid first, so a table inside another keeps its own text.
        var candidates: [(xs: [Double], ys: [Double], area: Double)] = []
        for g in groups {
            let xs = positions(g.v.map { $0.pos })
            let ys = positions(g.h.map { $0.pos })
            guard let x0 = xs.first, let x1 = xs.last, let y0 = ys.first, let y1 = ys.last else { continue }
            if xs.count >= 3 && ys.count >= 3 && (xs.count - 1) * (ys.count - 1) <= maxCells {
                candidates.append((xs, ys, (x1 - x0) * (y1 - y0)))
            }
        }
        candidates = ExportSort.stable(candidates) { ExportSort.before($0.area, $1.area) }

        var taken = Set<ExLine>()
        for (xs, ys, _) in candidates {
            let inside = lines.filter { !taken.contains($0) && $0.left >= xs[0] - snap && $0.left <= xs[xs.count - 1] && $0.centerY >= ys[0] && $0.centerY <= ys[ys.count - 1] }
            guard let table = fill(xs, ys, inside) else { continue }
            for l in inside { taken.insert(l) }
            found.append(ExportRuled(table: table, lines: inside))
        }
        return found
    }

    private static func fill(_ xs: [Double], _ ys: [Double], _ inside: [ExLine]) -> ExportTable? {
        let cols = xs.count - 1, rows = ys.count - 1
        var cells = [[ExLine]](repeating: [], count: rows * cols)
        let ordered = ExportSort.stable(inside) { a, b in
            ExportSort.before(a.centerY, b.centerY) || (!ExportSort.before(b.centerY, a.centerY) && ExportSort.before(a.left, b.left))
        }
        for line in ordered {
            let r = index(ys, line.centerY), c = max(0, index(xs, line.left + 1.5))
            cells[r * cols + c].append(line)
        }

        var texts = [String](repeating: "", count: rows * cols)
        var filled = 0
        for r in 0..<rows {
            for c in 0..<cols {
                let list = cells[r * cols + c]
                texts[r * cols + c] = list.isEmpty ? "" : cellText(list)
                if !texts[r * cols + c].isEmpty { filled += 1 }
            }
        }
        if filled < 3 { return nil }

        let keepRows = (0..<rows).filter { r in (0..<cols).contains { !texts[r * cols + $0].isEmpty } }
        let keepCols = (0..<cols).filter { c in keepRows.contains { !texts[$0 * cols + c].isEmpty } }
        if keepRows.count < 2 || keepCols.count < 2 { return nil }

        let body = keepRows.map { r in keepCols.map { c in texts[r * cols + c] } }
        let widths: [Double]? = keepCols.count == cols ? (0..<cols).map { xs[$0 + 1] - xs[$0] } : nil
        let bounds = DisplayRect(xs[0], ys[0], xs[xs.count - 1] - xs[0], ys[ys.count - 1] - ys[0])
        return ExportTable(bounds, body, widths, true)
    }

    // Lines of a cell in reading order: those within half a line of each other are one row of the cell.
    private static func cellText(_ lines: [ExLine]) -> String {
        var parts: [String] = []
        var row: [ExLine] = []
        func flush() {
            parts.append(ExportSort.stable(row) { ExportSort.before($0.left, $1.left) }.map { $0.text }.joined(separator: " "))
            row.removeAll()
        }
        for line in lines {
            if let first = row.first, line.centerY - first.centerY > 0.5 * line.size { flush() }
            row.append(line)
        }
        if !row.isEmpty { flush() }
        return ExportTrim.both(parts.joined(separator: " "))
    }

    private static func index(_ edges: [Double], _ value: Double) -> Int {
        let i = edges.lastIndex { $0 <= value } ?? -1
        return min(max(i, 0), edges.count - 2)
    }

    private static func positions(_ values: [Double]) -> [Double] {
        let sorted = ExportSort.stable(values) { ExportSort.before($0, $1) }
        var result: [Double] = []
        var last = -Double.infinity
        for v in sorted {
            if v - last > snap { result.append(v) }
            last = v
        }
        return result
    }

    // Lines on the same line of the page that touch or nearly touch become one.
    private static func merge(_ rules: [ExportRule]) -> [ExportRule] {
        let sorted = ExportSort.stable(rules) { ExportSort.before($0.pos, $1.pos) }
        var merged: [ExportRule] = []
        var i = 0
        while i < sorted.count {
            var j = i + 1
            while j < sorted.count && sorted[j].pos - sorted[j - 1].pos <= 1.5 { j += 1 }
            let cluster = Array(sorted[i..<j])
            var from = 0.0, to = 0.0
            var sum = 0.0
            for r in cluster { sum += r.pos }
            let pos = sum / Double(cluster.count)
            var open = false
            for r in ExportSort.stable(cluster, { ExportSort.before($0.from, $1.from) }) {
                if open && r.from <= to + gap {
                    to = max(to, r.to)
                    continue
                }
                if open { merged.append(ExportRule(horizontal: r.horizontal, pos: pos, from: from, to: to)) }
                (from, to, open) = (r.from, r.to, true)
            }
            merged.append(ExportRule(horizontal: sorted[i].horizontal, pos: pos, from: from, to: to))
            i = j
        }
        return merged
    }
}
