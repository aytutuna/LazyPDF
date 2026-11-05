import Foundation

// Twin of windows/LazyPDF.Core/Text/TextFlow.cs: turns glyphs into ordered lines: orientation groups, baselines,
// segments split at wide gaps, tables, paragraph chains, then a recursive cut of the blocks into reading order.

/// A line of the result: glyphs in logical order and how it joins the line before it.
final class FlowLine {
    var glyphs: [FlowGlyph] = []
    var before = TextBreak.none
    var block = 0
    var table = false, vertical = false, rtl = false
}

/// Glyphs on one baseline with no wide gap, in the frame of their orientation group.
final class FlowSeg {
    var glyphs: [FlowGlyph] = []
    var x0 = Double.greatestFiniteMagnitude, x1 = -Double.greatestFiniteMagnitude
    var ya = Double.greatestFiniteMagnitude, yb = -Double.greatestFiniteMagnitude
    var y = 0.0, em = 0.0
    var row = 0
    var text = 0, words = 0

    var width: Double { x1 - x0 }

    func finish() {
        let ink = glyphs.filter { !$0.space }
        let first = glyphs.firstIndex { !$0.space }, last = glyphs.lastIndex { !$0.space }
        if let first, let last {
            glyphs = Array(glyphs[first...last])
        } else {
            glyphs = []
        }
        text = ink.count
        words = 1
        for i in 1..<max(glyphs.count, 1) {
            let (a, b) = (glyphs[i - 1], glyphs[i])
            if !b.space && (a.space || b.x0 - a.x1 > 0.1 * (a.em + b.em) / 2) { words += 1 }
        }
        for g in ink {
            x0 = min(x0, g.x0)
            x1 = max(x1, g.x1)
            ya = min(ya, g.ya)
            yb = max(yb, g.yb)
        }
        if ink.isEmpty { return }
        y = Self.median(ink.map { $0.y })
        em = Self.median(ink.map { $0.em })
    }

    static func median(_ values: [Double]) -> Double {
        let a = values.sorted { compareDoubles($0, $1) < 0 }
        return a.isEmpty ? 0 : a[a.count / 2]
    }
}

/// A paragraph-like chain of segments, or a table.
final class FlowBlock {
    var segs: [FlowSeg] = []
    var x0 = Double.greatestFiniteMagnitude, x1 = -Double.greatestFiniteMagnitude
    var ya = Double.greatestFiniteMagnitude, yb = -Double.greatestFiniteMagnitude
    var table = false

    func add(_ s: FlowSeg) {
        segs.append(s)
        x0 = min(x0, s.x0)
        x1 = max(x1, s.x1)
        ya = min(ya, s.ya)
        yb = max(yb, s.yb)
    }
}

final class TextFlow {
    private static let columnGap = 1.2
    private static let spaceGap = 0.1

    private let geometry: PageGeometry
    private var block = 0
    private var dx = 0.0, dy = 0.0, nx = 0.0, ny = 0.0

    init(_ geometry: PageGeometry) {
        self.geometry = geometry
    }

    private struct GroupKey: Hashable {
        let vertical: Bool
        let bin: Int
    }

    func run(_ input: [FlowGlyph]) -> [FlowLine] {
        var result: [FlowLine] = []
        if input.isEmpty { return result }
        let m = geometry.matrix
        let scale = abs(m.a * m.d - m.b * m.c).squareRoot()
        for (i, g) in input.enumerated() { prepare(g, i, scale) }
        let glyphs = input.filter { g in
            let d = g.display
            return g.em.isFinite && (d.x0 + d.y0 + d.x1 + d.y1 + d.x2 + d.y2 + d.x3 + d.y3).isFinite
        }
        if glyphs.isEmpty { return result }

        // Groups come in the order they were first met; the biggest goes first, ties by that order.
        var keys: [GroupKey] = []
        var groups: [GroupKey: [FlowGlyph]] = [:]
        for g in glyphs {
            let bin = Int(saturating: (g.angle / (Double.pi / 12)).rounded(.toNearestOrEven))
            let key = GroupKey(vertical: g.vertical, bin: ((bin % 24) + 24) % 24)
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(g)
        }
        let order = keys.enumerated().sorted { a, b in
            let (ca, cb) = (groups[a.element]?.count ?? 0, groups[b.element]?.count ?? 0)
            return ca != cb ? ca > cb : a.offset < b.offset
        }
        for key in order { layout(groups[key.element] ?? [], &result) }
        return result
    }

    private func prepare(_ g: FlowGlyph, _ run: Int, _ scale: Double) {
        let q = g.quad
        let (x0, y0) = geometry.toDisplay(q.x0, q.y0)
        let (x1, y1) = geometry.toDisplay(q.x1, q.y1)
        let (x2, y2) = geometry.toDisplay(q.x2, q.y2)
        let (x3, y3) = geometry.toDisplay(q.x3, q.y3)
        g.display = TextQuad(x0, y0, x1, y1, x2, y2, x3, y3)
        g.em = g.size * scale
        g.run = run
        // The reading direction follows the baseline, so that a sheared matrix (fake italic) stays upright. Vertical
        // fonts and zero-width glyphs use the up vector turned a quarter clockwise.
        let bx = x1 - x0, by = y1 - y0
        var ux = x3 - x0, uy = y3 - y0
        let length = (ux * ux + uy * uy).squareRoot()
        if length < 1e-12 { (ux, uy) = (0, -1) }
        if !g.vertical && bx * bx + by * by > 1e-12 {
            g.angle = atan2(by, bx)
        } else {
            g.angle = g.vertical ? atan2(-uy, -ux) : atan2(ux, -uy)
        }
    }

    private func place(_ g: FlowGlyph) {
        let d = g.display
        let u = [dx * d.x0 + dy * d.y0, dx * d.x1 + dy * d.y1, dx * d.x2 + dy * d.y2, dx * d.x3 + dy * d.y3]
        let v = [nx * d.x0 + ny * d.y0, nx * d.x1 + ny * d.y1, nx * d.x2 + ny * d.y2, nx * d.x3 + ny * d.y3]
        g.x0 = min(min(u[0], u[1]), min(u[2], u[3]))
        g.x1 = max(max(u[0], u[1]), max(u[2], u[3]))
        g.ya = min(min(v[0], v[1]), min(v[2], v[3]))
        g.yb = max(max(v[0], v[1]), max(v[2], v[3]))
        if g.vertical {
            g.y = (g.ya + g.yb) / 2
            return
        }
        let bx = d.x0 + g.base * (d.x3 - d.x0), by = d.y0 + g.base * (d.y3 - d.y0)
        g.y = nx * bx + ny * by
    }

    private func layout(_ group: [FlowGlyph], _ result: inout [FlowLine]) {
        guard let head = group.first else { return }
        let vertical = head.vertical
        let centre = Double(Int(saturating: (head.angle / (Double.pi / 12)).rounded(.toNearestOrEven))) * (Double.pi / 12)
        let phi = centre + FlowSeg.median(group.map { ($0.angle - centre).remainder(dividingBy: 2 * Double.pi) })
        (dx, dy) = (cos(phi), sin(phi))
        (nx, ny) = (-dy, dx)
        for g in group { place(g) }

        var rtlCount = 0, ltrCount = 0
        for g in group {
            let cls = TextBidi.classOf(g.text)
            if cls == .r {
                rtlCount += 1
            } else if cls == .l {
                ltrCount += 1
            }
        }
        let pageRtl = rtlCount > ltrCount

        let lines = self.lines(group)
        var segs: [FlowSeg] = []
        for (i, line) in lines.enumerated() {
            for s in line {
                s.row = i
                segs.append(s)
            }
        }
        if segs.isEmpty { return }
        let em = FlowSeg.median(segs.map { $0.em })
        let blocks = TextTables.blocks(lines, em)
        let order = TextOrder.sort(blocks, em, pageRtl)

        var previous: FlowSeg?
        let first = result.isEmpty
        for b in order {
            let number = block
            block += 1
            var last: FlowSeg?
            for seg in b.segs {
                let line = FlowLine()
                line.block = number
                line.table = b.table
                line.vertical = vertical
                if let previous {
                    if let last {
                        line.before = b.table && last.row == seg.row ? .tab : .line
                    } else {
                        line.before = Self.sameRow(previous, seg) ? .tab : .block
                    }
                } else {
                    line.before = first ? .none : .block
                }
                let (glyphs, rtl) = logical(seg, pageRtl)
                line.glyphs = glyphs
                line.rtl = rtl
                result.append(line)
                previous = seg
                last = seg
            }
        }
    }

    private static func sameRow(_ a: FlowSeg, _ b: FlowSeg) -> Bool { abs(a.y - b.y) < 0.3 * max(a.em, b.em) }

    // Lines: glyphs on one baseline, found by sorting on it and cutting where it jumps, then script glyphs (smaller,
    // shifted off the baseline) are taken into the line they sit beside. Split at gaps too wide for a word space.
    private func lines(_ group: [FlowGlyph]) -> [[FlowSeg]] {
        let sorted = group.sorted { a, b in
            let c = compareDoubles(a.y, b.y)
            return c != 0 ? c < 0 : a.run < b.run
        }
        var lines: [[FlowGlyph]] = []
        var first = 0.0
        for (i, g) in sorted.enumerated() {
            if i > 0 && g.y - sorted[i - 1].y <= 0.35 * min(g.em, sorted[i - 1].em) && g.y - first <= 0.7 * g.em, !lines.isEmpty {
                lines[lines.count - 1].append(g)
                continue
            }
            lines.append([g])
            first = g.y
        }
        lines = Self.attachScripts(lines)

        var result: [[FlowSeg]] = []
        for var line in lines {
            line.sort { p, q in
                p.x0 != q.x0 ? compareDoubles(p.x0, q.x0) < 0 : p.run < q.run
            }
            var segs: [FlowSeg] = []
            var cur = FlowSeg()
            var right = -Double.greatestFiniteMagnitude, lastEm = 0.0
            for g in line {
                if !cur.glyphs.isEmpty && g.x0 - right > Self.columnGap * max(g.em, lastEm) {
                    segs.append(cur)
                    cur = FlowSeg()
                }
                cur.glyphs.append(g)
                if !g.space {
                    right = cur.glyphs.count == 1 || right == -Double.greatestFiniteMagnitude ? g.x1 : max(right, g.x1)
                    lastEm = g.em
                }
            }
            segs.append(cur)
            for s in segs { s.finish() }
            segs.removeAll { $0.glyphs.isEmpty }
            if !segs.isEmpty { result.append(segs) }
        }
        return result
    }

    private static func attachScripts(_ lines: [[FlowGlyph]]) -> [[FlowGlyph]] {
        let stats = lines.map { l in
            (y: FlowSeg.median(l.map { $0.y }), em: FlowSeg.median(l.map { $0.em }),
             x0: l.map { $0.x0 }.min() ?? 0, x1: l.map { $0.x1 }.max() ?? 0)
        }
        var target = Array(0..<lines.count)
        for i in 0..<lines.count {
            var best = -1
            var bestDistance = Double.greatestFiniteMagnitude
            for j in max(0, i - 3)...min(lines.count - 1, i + 3) {
                if j == i || stats[j].em * 0.85 < stats[i].em || stats[i].em < 0.55 * stats[j].em { continue }
                let d = abs(stats[j].y - stats[i].y)
                let beside = stats[i].x1 >= stats[j].x0 - stats[j].em && stats[i].x0 <= stats[j].x1 + stats[j].em
                if d < 0.7 * stats[j].em && beside && d < bestDistance {
                    best = j
                    bestDistance = d
                }
            }
            if best >= 0 { target[i] = best }
        }
        var result: [[FlowGlyph]] = []
        var index: [Int: Int] = [:]
        for i in 0..<lines.count {
            var t = target[i]
            while target[t] != t { t = target[t] }
            var at = index[t] ?? -1
            if at < 0 {
                at = result.count
                index[t] = at
                result.append([])
            }
            result[at].append(contentsOf: lines[i])
        }
        return result
    }

    // A line's glyphs in logical order with a space glyph wherever a gap is wide enough to be one.
    private func logical(_ seg: FlowSeg, _ pageRtl: Bool) -> (glyphs: [FlowGlyph], rtl: Bool) {
        var visual: [FlowGlyph] = []
        visual.reserveCapacity(seg.glyphs.count + 8)
        var prev: FlowGlyph?
        for g in seg.glyphs {
            if let p = prev, !p.space, !g.space, g.x0 - p.x1 > Self.spaceGap * (p.em + g.em) / 2 { visual.append(gap(p, g)) }
            visual.append(g)
            prev = g
        }
        let rtl = TextBidi.toLogical(&visual, pageRtl)
        return (visual, rtl)
    }

    private func gap(_ a: FlowGlyph, _ b: FlowGlyph) -> FlowGlyph {
        let ya = (a.ya + b.ya) / 2, yb = (a.yb + b.yb) / 2, u0 = a.x1, u1 = b.x0
        func p(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
            geometry.toUser(u * dx + v * nx, u * dy + v * ny)
        }
        let (p0, p1, p2, p3) = a.vertical ? (p(u1, yb), p(u1, ya), p(u0, ya), p(u0, yb)) : (p(u0, yb), p(u1, yb), p(u1, ya), p(u0, ya))
        let g = FlowGlyph()
        g.text = " "
        g.quad = TextQuad(p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y)
        g.size = a.size
        g.color = a.color
        g.mode = a.mode
        g.artifact = a.artifact
        g.vertical = a.vertical
        g.space = true
        g.implied = true
        g.x0 = u0
        g.x1 = u1
        g.y = a.y
        g.ya = ya
        g.yb = yb
        g.em = a.em
        return g
    }
}
