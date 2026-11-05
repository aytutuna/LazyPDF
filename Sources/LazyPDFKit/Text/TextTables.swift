import Foundation

// Twin of windows/LazyPDF.Core/Text/TextTables.cs: groups segments into tables and paragraph chains.

enum TextTables {
    private static let maxRowChars = 24.0
    private static let maxRowWords = 3.0
    private static let maxLookBack = 200

    static func blocks(_ lines: [[FlowSeg]], _ em: Double) -> [FlowBlock] {
        var blocks: [FlowBlock] = []
        var loose: [FlowSeg] = []
        var run: [[FlowSeg]] = []

        func flush() {
            let table = run.count >= 3 || (run.count == 2 && run.allSatisfy { $0.count >= 3 })
            if table {
                let block = FlowBlock()
                block.table = true
                for line in run {
                    for s in line { block.add(s) }
                }
                blocks.append(block)
            } else {
                for line in run { loose.append(contentsOf: line) }
            }
            run.removeAll()
        }

        for (i, line) in lines.enumerated() {
            let row = isRow(line)
            if row, let tail = run.last, (line.map { $0.ya }.min() ?? 0) - (tail.map { $0.yb }.max() ?? 0) > 1.5 * em { flush() }
            if row {
                run.append(line)
                continue
            }
            // A row with one filled cell stays in the table when more rows follow in line with it.
            if let tail = run.last, line.count == 1, i + 1 < lines.count, isRow(lines[i + 1]), alignsWith(line[0], tail) {
                run.append(line)
                continue
            }
            flush()
            loose.append(contentsOf: line)
        }
        flush()
        blocks.append(contentsOf: chains(&loose))
        return blocks
    }

    private static func isRow(_ line: [FlowSeg]) -> Bool {
        line.count >= 2 && FlowSeg.median(line.map { Double($0.text) }) <= maxRowChars && FlowSeg.median(line.map { Double($0.words) }) <= maxRowWords
    }

    private static func alignsWith(_ cell: FlowSeg, _ row: [FlowSeg]) -> Bool { row.contains { abs($0.x0 - cell.x0) < 0.6 * cell.em } }

    // Each segment hangs under the one above it that it overlaps most, at most one child per parent so that text under a
    // heading that spans two columns does not join both columns.
    private static func chains(_ segs: inout [FlowSeg]) -> [FlowBlock] {
        segs.sort { a, b in a.y != b.y ? compareDoubles(a.y, b.y) < 0 : compareDoubles(a.x0, b.x0) < 0 }
        var candidates = [[(parent: Int, overlap: Double, dy: Double)]](repeating: [], count: segs.count)
        var nearest: [Double] = []
        for i in 0..<segs.count {
            let s = segs[i]
            var closest = Double.greatestFiniteMagnitude
            for j in stride(from: i - 1, through: max(0, i - maxLookBack), by: -1) {
                let p = segs[j]
                let dy = s.y - p.y
                if dy > 2.6 * max(s.em, p.em) { break }
                let ratio = s.em / p.em, overlap = min(s.x1, p.x1) - max(s.x0, p.x0)
                if dy < 0.5 * max(s.em, p.em) || ratio < 0.7 || ratio > 1.43 { continue }
                if overlap <= 0 || overlap < 0.3 * min(s.width, p.width) { continue }
                candidates[i].append((j, overlap, dy))
                closest = min(closest, dy)
            }
            if closest < Double.greatestFiniteMagnitude { nearest.append(closest) }
        }
        // A gap well past the usual line pitch is a paragraph break.
        nearest.sort { compareDoubles($0, $1) < 0 }
        let pitch = nearest.isEmpty ? 0 : nearest[nearest.count / 2]
        var parent = [FlowSeg?](repeating: nil, count: segs.count)
        var hasChild = [Bool](repeating: false, count: segs.count)
        for i in 0..<segs.count {
            var best = -1
            var bestOverlap = 0.0
            for (j, overlap, dy) in candidates[i] {
                if hasChild[j] || dy > max(1.45 * pitch, 1.3 * segs[i].em) { continue }
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    best = j
                }
            }
            if best < 0 { continue }
            hasChild[best] = true
            parent[i] = segs[best]
        }

        var owner: [ObjectIdentifier: FlowBlock] = [:]
        owner.reserveCapacity(segs.count)
        var result: [FlowBlock] = []
        for i in 0..<segs.count {
            var block: FlowBlock?
            if let p = parent[i] { block = owner[ObjectIdentifier(p)] }
            if block == nil {
                let created = FlowBlock()
                result.append(created)
                block = created
            }
            block?.add(segs[i])
            owner[ObjectIdentifier(segs[i])] = block
        }
        return result
    }
}
