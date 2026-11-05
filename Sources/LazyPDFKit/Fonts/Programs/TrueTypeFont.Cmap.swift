import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/TrueTypeFont.Cmap.cs: the character map of an sfnt font.

extension TrueTypeFont {
    func readCmapDirectory() {
        let cmap = table("cmap")
        let count = min(cmap.u16(2), (cmap.length - 4) / 8)
        var list: [CmapSubtable] = []
        var i = 0
        while i < count {
            let offset = cmap.offset32(4 + 8 * i + 4)
            if offset > 0 && offset < cmap.length - 4 {
                list.append(CmapSubtable(platform: cmap.u16(4 + 8 * i), encoding: cmap.u16(4 + 8 * i + 2), offset: offset))
            }
            i += 1
        }
        cmaps = list

        // Wide subtables first so code points above the BMP resolve.
        let unicodeOrder = [(3, 10), (0, 6), (0, 4), (3, 1), (0, 3), (0, 2), (0, 1), (0, 0)]
        for (p, e) in unicodeOrder {
            var k = 0
            while k < cmaps.count && unicode < 0 {
                if cmaps[k].platform == p && cmaps[k].encoding == e && TrueTypeFont.isLookupFormat(cmap.u16(cmaps[k].offset)) {
                    unicode = k
                }
                k += 1
            }
            if unicode >= 0 { break }
        }
        symbol = cmaps.firstIndex { $0.platform == 3 && $0.encoding == 0 } ?? -1
    }

    private static func isLookupFormat(_ format: Int) -> Bool {
        format == 0 || format == 4 || format == 6 || format == 12 || format == 13
    }

    /// True when the font has a cmap subtable for the platform and encoding IDs.
    public func hasCmap(_ platformId: Int, _ encodingId: Int) -> Bool {
        cmaps.contains { $0.platform == platformId && $0.encoding == encodingId }
    }

    /// Glyph for a Unicode code point, 0 (.notdef) when the font has none. A font with only a (3,0) symbol
    /// subtable is asked for the code itself and for 0xF000 plus it, the way viewers do.
    public func glyphForCodePoint(_ codePoint: Int) -> Int {
        let cmap = table("cmap")
        if unicode >= 0 {
            let g = TrueTypeFont.lookup(cmap, cmaps[unicode].offset, codePoint)
            if g != 0 { return g }
        }
        if unicode < 0 && symbol >= 0 && codePoint >= 0 && codePoint < 256 {
            let offset = cmaps[symbol].offset
            let g = TrueTypeFont.lookup(cmap, offset, codePoint)
            return g != 0 ? g : TrueTypeFont.lookup(cmap, offset, 0xF000 + codePoint)
        }
        return 0
    }

    /// Glyph for a code in one named cmap subtable, 0 when the subtable or the code is absent.
    public func glyphForCmap(_ platformId: Int, _ encodingId: Int, _ code: Int) -> Int {
        guard let i = cmaps.firstIndex(where: { $0.platform == platformId && $0.encoding == encodingId }) else { return 0 }
        return TrueTypeFont.lookup(table("cmap"), cmaps[i].offset, code)
    }

    /// Glyph for a base character followed by a variation selector, from the format 14 subtable (0,5).
    /// Returns 0 when the font lists no such sequence; a default sequence gives the base character's glyph.
    public func glyphForVariation(_ codePoint: Int, _ variationSelector: Int) -> Int {
        guard let i = cmaps.firstIndex(where: { $0.platform == 0 && $0.encoding == 5 }) else { return 0 }
        let sub = table("cmap").slice(from: cmaps[i].offset)
        if sub.u16(0) != 14 { return 0 }

        let count = min(sub.offset32(6), (sub.length - 10) / 11)
        var lo = 0
        var hi = count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let rec = 10 + 11 * mid
            let vs = sub.u24(rec)
            if vs < variationSelector {
                lo = mid + 1
            } else if vs > variationSelector {
                hi = mid - 1
            } else {
                let nonDefault = sub.offset32(rec + 7)
                if nonDefault > 0 {
                    let n = min(sub.offset32(nonDefault), (sub.length - nonDefault - 4) / 5)
                    var a = 0
                    var b = n - 1
                    while a <= b {
                        let m = (a + b) / 2
                        let at = nonDefault + 4 + 5 * m
                        let u = sub.u24(at)
                        if u < codePoint {
                            a = m + 1
                        } else if u > codePoint {
                            b = m - 1
                        } else {
                            return sub.u16(at + 3)
                        }
                    }
                }
                let def = sub.offset32(rec + 3)
                if def > 0 {
                    let n = min(sub.offset32(def), (sub.length - def - 4) / 4)
                    var a = 0
                    var b = n - 1
                    while a <= b {
                        let m = (a + b) / 2
                        let at = def + 4 + 4 * m
                        let start = sub.u24(at)
                        if codePoint < start {
                            b = m - 1
                        } else if codePoint > start + sub.u8(at + 3) {
                            a = m + 1
                        } else {
                            return glyphForCodePoint(codePoint)
                        }
                    }
                }
                return 0
            }
        }
        return 0
    }

    private static func lookup(_ cmap: FontSpan, _ offset: Int, _ code: Int) -> Int {
        if code < 0 { return 0 }
        let t = cmap.slice(from: offset)
        switch t.u16(0) {
        case 0:
            return code < 256 ? t.u8(6 + code) : 0
        case 4:
            return lookupFormat4(t, code)
        case 6:
            let first = t.u16(6)
            let n = t.u16(8)
            return code >= first && code - first < n ? t.u16(10 + 2 * (code - first)) : 0
        case 12, 13:
            let n = min(t.offset32(12), (t.length - 16) / 12)
            var lo = 0
            var hi = n - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let g = 16 + 12 * mid
                let start = Int(t.u32(g))
                if code < start {
                    hi = mid - 1
                } else if code > Int(t.u32(g + 4)) {
                    lo = mid + 1
                } else {
                    var gid = t.u32(g + 8)
                    // uint arithmetic: the sum wraps like it does in the C#.
                    gid = t.u16(0) == 13 ? gid : gid &+ UInt32(truncatingIfNeeded: code) &- UInt32(truncatingIfNeeded: start)
                    return gid > 0xFFFF ? 0 : Int(gid)
                }
            }
            return 0
        default:
            return 0
        }
    }

    private static func lookupFormat4(_ t: FontSpan, _ code: Int) -> Int {
        if code > 0xFFFF { return 0 }
        let segCount = min(t.u16(6) / 2, (t.length - 16) / 8)
        let ends = 14
        let starts = 16 + 2 * segCount
        let deltas = starts + 2 * segCount
        let ranges = deltas + 2 * segCount

        var lo = 0
        var hi = segCount - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if t.u16(ends + 2 * mid) < code { lo = mid + 1 } else { hi = mid }
        }
        if lo >= segCount || t.u16(ends + 2 * lo) < code || t.u16(starts + 2 * lo) > code { return 0 }

        let delta = t.u16(deltas + 2 * lo)
        let range = t.u16(ranges + 2 * lo)
        if range == 0 { return (code + delta) & 0xFFFF }
        let g = t.u16(ranges + 2 * lo + range + 2 * (code - t.u16(starts + 2 * lo)))
        return g == 0 ? 0 : (g + delta) & 0xFFFF
    }
}
