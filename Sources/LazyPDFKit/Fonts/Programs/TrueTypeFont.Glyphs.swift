import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/TrueTypeFont.Glyphs.cs: glyph data, boxes and outlines of an sfnt font.

private let maxCompositeDepth = 8
private let maxComponents = 512
private let maxPoints = 100_000

private struct Pt {
    var x: Double
    var y: Double
    var on: Bool
}

private final class Contours {
    var points: [Pt] = []
    var ends: [Int] = []
}

extension TrueTypeFont {
    /// The glyph's data in 'glyf', empty for a blank glyph or one whose loca entry is out of range.
    func glyphData(_ glyphId: Int) -> FontSpan {
        if glyphId < 0 || glyphId >= glyphCount { return .empty }
        let loca = table("loca")
        let glyf = table("glyf")
        let start: Int
        var end: Int
        if locaFormat == 0 {
            start = loca.u16(2 * glyphId) * 2
            end = loca.u16(2 * glyphId + 2) * 2
        } else {
            start = loca.offset32(4 * glyphId)
            end = loca.offset32(4 * glyphId + 4)
        }
        end = min(end, glyf.length)
        return start < end ? glyf.slice(start, end - start) : .empty
    }

    /// Box of the glyph in font units, nil for an empty glyph. TrueType reads the glyph header, CFF measures the outline.
    public func getBounds(_ glyphId: Int) -> GlyphBounds? {
        if let cff { return cff.getOutline(glyphId)?.bounds() }
        let g = glyphData(glyphId)
        if g.length < 10 { return nil }
        return GlyphBounds(Double(g.i16(2)), Double(g.i16(4)), Double(g.i16(6)), Double(g.i16(8)))
    }

    /// The outline of a glyph, composites resolved, in font units. Empty for a blank glyph, nil when the glyph
    /// does not exist or the font has no outlines. Broken glyph data gives an empty outline.
    public func getOutline(_ glyphId: Int) -> GlyphOutline? {
        if glyphId < 0 || glyphId >= glyphCount { return nil }
        if let cff { return cff.getOutline(glyphId) }
        if !hasOutlines { return nil }

        var budget = maxComponents
        var points = maxPoints
        let outline = GlyphOutline()
        if let c = load(glyphId, 0, &budget, &points) { emit(outline, c) }
        return outline
    }

    private func load(_ glyphId: Int, _ depth: Int, _ budget: inout Int, _ points: inout Int) -> Contours? {
        let g = glyphData(glyphId)
        if g.length < 10 { return Contours() }
        let n = g.i16(0)
        if n < 0 { return loadComposite(g, depth, &budget, &points) }
        // A glyph that components repeat is counted each time: the points are built for each of them.
        guard let simple = TrueTypeFont.loadSimple(g, n) else { return nil }
        points -= simple.points.count
        return points >= 0 ? simple : nil
    }

    private static func loadSimple(_ g: FontSpan, _ contourCount: Int) -> Contours? {
        let result = Contours()
        if contourCount == 0 { return result }
        var p = 10
        var last = -1
        for _ in 0..<contourCount {
            let end = g.u16(p)
            if end < last { return nil }
            result.ends.append(end)
            last = end
            p += 2
        }
        let count = last + 1
        p += 2 + g.u16(p)
        if p > g.length { return nil }

        var flags = [UInt8](repeating: 0, count: count)
        var i = 0
        while i < count {
            if p >= g.length { return nil }
            let f = g[p]
            p += 1
            flags[i] = f
            i += 1
            if f & 8 == 0 { continue }
            if p >= g.length { return nil }
            var r = g[p]
            p += 1
            while r > 0 && i < count {
                flags[i] = f
                i += 1
                r -= 1
            }
        }

        var xs = [Double](repeating: 0, count: count)
        var ys = [Double](repeating: 0, count: count)
        if !readCoords(g, &p, flags, &xs, 0x02, 0x10) || !readCoords(g, &p, flags, &ys, 0x04, 0x20) { return nil }

        result.points.reserveCapacity(count)
        for k in 0..<count { result.points.append(Pt(x: xs[k], y: ys[k], on: flags[k] & 1 != 0)) }
        return result
    }

    private static func readCoords(_ g: FontSpan, _ p: inout Int, _ flags: [UInt8], _ into: inout [Double], _ shortBit: UInt8, _ sameBit: UInt8) -> Bool {
        var v = 0
        for i in 0..<flags.count {
            let f = flags[i]
            if f & shortBit != 0 {
                if p >= g.length { return false }
                let d = Int(g[p])
                p += 1
                v += f & sameBit != 0 ? d : -d
            } else if f & sameBit == 0 {
                if p > g.length - 2 { return false }
                v += g.i16(p)
                p += 2
            }
            into[i] = Double(v)
        }
        return true
    }

    private func loadComposite(_ g: FontSpan, _ depth: Int, _ budget: inout Int, _ points: inout Int) -> Contours? {
        let result = Contours()
        if depth >= maxCompositeDepth { return result }
        var p = 10
        while true {
            if p > g.length - 4 { return result }
            budget -= 1
            if budget < 0 { return result }
            let flags = g.u16(p)
            let component = g.u16(p + 2)
            p += 4

            let a1: Int
            let a2: Int
            let xy = (flags & 2) != 0
            if (flags & 1) != 0 {
                a1 = xy ? g.i16(p) : g.u16(p)
                a2 = xy ? g.i16(p + 2) : g.u16(p + 2)
                p += 4
            } else {
                a1 = xy ? Int(Int8(truncatingIfNeeded: g.u8(p))) : g.u8(p)
                a2 = xy ? Int(Int8(truncatingIfNeeded: g.u8(p + 1))) : g.u8(p + 1)
                p += 2
            }

            var xx = 1.0
            var xy01 = 0.0
            var yx10 = 0.0
            var yy = 1.0
            if (flags & 0x8) != 0 {
                xx = TrueTypeFont.f2Dot14(g, p)
                yy = xx
                p += 2
            } else if (flags & 0x40) != 0 {
                xx = TrueTypeFont.f2Dot14(g, p)
                yy = TrueTypeFont.f2Dot14(g, p + 2)
                p += 4
            } else if (flags & 0x80) != 0 {
                xx = TrueTypeFont.f2Dot14(g, p)
                xy01 = TrueTypeFont.f2Dot14(g, p + 2)
                yx10 = TrueTypeFont.f2Dot14(g, p + 4)
                yy = TrueTypeFont.f2Dot14(g, p + 6)
                p += 8
            }

            if let child = load(component, depth + 1, &budget, &points) {
                for i in 0..<child.points.count {
                    let pt = child.points[i]
                    child.points[i] = Pt(x: xx * pt.x + yx10 * pt.y, y: xy01 * pt.x + yy * pt.y, on: pt.on)
                }

                var dx = Double(a1)
                var dy = Double(a2)
                if !xy {
                    // Point matching: the child point a2 lands on the parent point a1.
                    if a1 < result.points.count && a2 < child.points.count {
                        dx = result.points[a1].x - child.points[a2].x
                        dy = result.points[a1].y - child.points[a2].y
                    } else {
                        dx = 0
                        dy = 0
                    }
                }

                let baseIndex = result.points.count
                for pt in child.points { result.points.append(Pt(x: pt.x + dx, y: pt.y + dy, on: pt.on)) }
                for e in child.ends { result.ends.append(e + baseIndex) }
            }

            if (flags & 0x20) == 0 { return result }
        }
    }

    private static func f2Dot14(_ d: FontSpan, _ o: Int) -> Double {
        Double(d.i16(o)) / 16384.0
    }

    private func emit(_ outline: GlyphOutline, _ c: Contours) {
        var first = 0
        for end in c.ends {
            let last = min(end, c.points.count - 1)
            if last - first >= 1 { emitContour(outline, c.points, first, last) }
            first = end + 1
        }
    }

    private func emitContour(_ o: GlyphOutline, _ pts: [Pt], _ s: Int, _ e: Int) {
        let start: Pt
        let from: Int
        let to: Int
        if pts[s].on {
            start = pts[s]
            from = s + 1
            to = e
        } else if pts[e].on {
            start = pts[e]
            from = s
            to = e - 1
        } else {
            start = Pt(x: (pts[s].x + pts[e].x) / 2, y: (pts[s].y + pts[e].y) / 2, on: true)
            from = s
            to = e
        }

        o.moveTo(start.x, start.y)
        var ctrl: Pt?
        var i = from
        while i <= to {
            let p = pts[i]
            i += 1
            if p.on {
                if let c = ctrl {
                    o.quadTo(c.x, c.y, p.x, p.y)
                } else {
                    o.lineTo(p.x, p.y)
                }
                ctrl = nil
            } else {
                if let c = ctrl { o.quadTo(c.x, c.y, (c.x + p.x) / 2, (c.y + p.y) / 2) }
                ctrl = p
            }
        }
        if let last = ctrl { o.quadTo(last.x, last.y, start.x, start.y) }
        o.close()
    }
}
