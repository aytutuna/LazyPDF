import Foundation

// Twin of windows/LazyPDF.Core/Text/TextOrder.cs: reading order of blocks by recursive cuts, across the widest empty
// bands first, then between columns. Bands that are columnar on both sides of a cut and share a gutter are kept
// together, otherwise two columns whose paragraph gaps happen to line up would be read across.

final class TextOrder {
    private static let maxDepth = 48
    private static let maxBlocks = 20_000

    private let em: Double
    private let rtl: Bool
    private var result: [FlowBlock] = []

    private init(_ em: Double, _ rtl: Bool) {
        self.em = em
        self.rtl = rtl
    }

    static func sort(_ blocks: [FlowBlock], _ em: Double, _ rtl: Bool) -> [FlowBlock] {
        if rtl {
            for b in blocks where b.table {
                b.segs = stableSorted(b.segs) { x, y in x.row != y.row ? x.row < y.row : compareDoubles(x.x0, y.x0) > 0 }
            }
        }
        let order = TextOrder(em, rtl)
        if blocks.count > maxBlocks {
            order.leaf(blocks)
        } else {
            order.cut(blocks, true, 0)
        }
        return order.result
    }

    private func cut(_ items: [FlowBlock], _ horizontal: Bool, _ depth: Int) {
        if items.count <= 1 {
            result.append(contentsOf: items)
            return
        }
        if depth > Self.maxDepth {
            leaf(items)
            return
        }
        if horizontal {
            let bands = merge(self.bands(items))
            if bands.count > 1 || bands.first?.merged == true {
                for band in bands { cut(band.items, !band.merged, depth + 1) }
                return
            }
        }
        var columns = self.columns(items)
        if columns.count < 2 {
            leaf(items)
            return
        }
        if rtl { columns.reverse() }
        for column in columns { cut(column, true, depth + 1) }
    }

    private struct Band {
        let items: [FlowBlock]
        let merged: Bool
    }

    private func bands(_ items: [FlowBlock]) -> [Band] {
        let sorted = Self.stableSorted(items) { a, b in
            let c = compareDoubles(a.ya, b.ya)
            return c != 0 ? c < 0 : compareDoubles(a.x0, b.x0) < 0
        }
        var bands: [Band] = []
        var current: [FlowBlock] = []
        var bottom = -Double.greatestFiniteMagnitude
        for b in sorted {
            if !current.isEmpty && b.ya > bottom + 0.05 * em {
                bands.append(Band(items: current, merged: false))
                current = []
            }
            current.append(b)
            bottom = current.count == 1 ? b.yb : max(bottom, b.yb)
        }
        bands.append(Band(items: current, merged: false))
        return bands
    }

    private func merge(_ bands: [Band]) -> [Band] {
        if bands.count < 2 { return bands }
        var merged: [Band] = []
        var previous: [(left: Double, right: Double)]?
        for band in bands {
            let gutters = Self.gutters(columns(band.items))
            if let last = merged.last, let before = previous, !before.isEmpty, !gutters.isEmpty, shares(before, gutters) {
                merged[merged.count - 1] = Band(items: last.items + band.items, merged: true)
            } else {
                merged.append(band)
            }
            previous = gutters
        }
        return merged
    }

    private func shares(_ a: [(left: Double, right: Double)], _ b: [(left: Double, right: Double)]) -> Bool {
        a.contains { x in b.contains { y in min(x.right, y.right) - max(x.left, y.left) > 0.3 * em } }
    }

    private static func gutters(_ columns: [[FlowBlock]]) -> [(left: Double, right: Double)] {
        var result: [(left: Double, right: Double)] = []
        for i in stride(from: 1, to: columns.count, by: 1) {
            result.append((columns[i - 1].map { $0.x1 }.max() ?? 0, columns[i].map { $0.x0 }.min() ?? 0))
        }
        return result
    }

    // Gutters are stretches of x that almost nothing covers, so that a page number sitting in one does not make two
    // columns one. A block belongs to the column its centre is in.
    private func columns(_ items: [FlowBlock]) -> [[FlowBlock]] {
        let limit = 0.04 * items.reduce(0.0) { $0 + ($1.yb - $1.ya) }
        var edges: [(x: Double, weight: Double)] = []
        edges.reserveCapacity(items.count * 2)
        for b in items {
            edges.append((b.x0, b.yb - b.ya))
            edges.append((b.x1, b.ya - b.yb))
        }
        edges = Self.stableSorted(edges) { compareDoubles($0.x, $1.x) < 0 }
        var xs: [Double] = []
        var cover: [Double] = []
        var sum = 0.0
        var i = 0
        while i < edges.count {
            let x = edges[i].x
            repeat {
                sum += edges[i].weight
                i += 1
            } while i < edges.count && edges[i].x == x
            xs.append(x)
            cover.append(sum)
        }
        var gutters: [Double] = []
        i = 0
        while i < xs.count - 1 {
            if cover[i] > limit {
                i += 1
                continue
            }
            var j = i + 1
            while j < xs.count - 1 && cover[j] <= limit { j += 1 }
            if i > 0 && j < xs.count - 1 && xs[j] - xs[i] > 0.9 * em { gutters.append((xs[i] + xs[j]) / 2) }
            i = j
        }
        var byColumn: [Int: [FlowBlock]] = [:]
        for b in items {
            let centre = (b.x0 + b.x1) / 2
            let k = gutters.filter { $0 < centre }.count
            byColumn[k, default: []].append(b)
        }
        return byColumn.keys.sorted().map { byColumn[$0] ?? [] }
    }

    // Nothing separates these: rows from the top, each row left to right.
    private func leaf(_ items: [FlowBlock]) {
        let sorted = Self.stableSorted(items) { a, b in
            let c = compareDoubles(a.ya, b.ya)
            return c != 0 ? c < 0 : compareDoubles(a.x0, b.x0) < 0
        }
        var row: [FlowBlock] = []
        var head: FlowBlock?

        func flush() {
            let ordered = rtl ? Self.stableSorted(row) { compareDoubles($0.x1, $1.x1) > 0 } : Self.stableSorted(row) { compareDoubles($0.x0, $1.x0) < 0 }
            result.append(contentsOf: ordered)
            row.removeAll()
        }

        for b in sorted {
            if let h = head, b.ya >= h.ya + 0.5 * (h.yb - h.ya) { flush() }
            if row.isEmpty { head = b }
            row.append(b)
        }
        flush()
    }

    /// `OrderBy`: the order of equal elements is kept.
    private static func stableSorted<T>(_ items: [T], _ less: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map { $0.element }
    }
}
