import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/TrueTypeFont.cs: an sfnt font, TrueType outlines (glyf) or OpenType
// with CFF outlines. Parses over the caller's array and tolerates broken tables: a missing or truncated table
// gives zeros and empty outlines, never a trap.

public final class TrueTypeFont {
    private let data: [UInt8]
    private let tables: [String: (offset: Int, length: Int)]
    let locaFormat: Int
    let hMetricCount: Int

    public let unitsPerEm: Int
    public let glyphCount: Int

    /// Typographic ascent in font units (hhea, else OS/2), positive.
    public let ascent: Int

    /// Descent in font units, negative below the baseline.
    public let descent: Int

    public let lineGap: Int

    public private(set) var capHeight = 0

    public let xHeight: Int

    /// Box around all glyphs, from head.
    public let fontBounds: GlyphBounds

    public let italicAngle: Double

    public let isFixedPitch: Bool

    public let isBoldStyle: Bool

    /// usWeightClass of OS/2, 400 when the table is absent.
    public let weightClass: Int

    /// The OS/2 licensing bits, 0 (installable) when the font has no OS/2 table.
    public let fsType: Int

    /// The CFF outlines of an OpenType/CFF font, nil for TrueType outlines.
    public let cff: CffFont?

    struct CmapSubtable {
        var platform: Int
        var encoding: Int
        var offset: Int
    }

    var cmaps: [CmapSubtable] = []
    var unicode = -1
    var symbol = -1
    var glyphNames: [String?]?
    var nameToGlyph: [String: Int]?

    private init(_ data: [UInt8], _ tables: [String: (offset: Int, length: Int)]) {
        self.data = data
        self.tables = tables

        func table(_ tag: String) -> FontSpan {
            guard let t = tables[tag] else { return .empty }
            return FontSpan(data, t.offset, t.length)
        }

        let head = table("head")
        var upem = head.u16(18)
        if upem < 16 || upem > 16384 { upem = 1000 }
        unitsPerEm = upem
        fontBounds = GlyphBounds(Double(head.i16(36)), Double(head.i16(38)), Double(head.i16(40)), Double(head.i16(42)))
        isBoldStyle = (head.u16(44) & 1) != 0
        locaFormat = head.i16(50)

        glyphCount = table("maxp").u16(4)

        let hhea = table("hhea")
        var asc = hhea.i16(4)
        var desc = hhea.i16(6)
        lineGap = hhea.i16(8)
        hMetricCount = hhea.u16(34)

        var weight = 400
        var fs = 0
        var xh = 0
        var cap = 0
        let os2 = table("OS/2")
        if os2.length >= 10 {
            weight = os2.u16(4)
            fs = os2.u16(8)
            if asc == 0 && desc == 0 {
                asc = os2.i16(68)
                desc = os2.i16(70)
                if asc == 0 && desc == 0 {
                    asc = os2.u16(74)
                    desc = -os2.u16(76)
                }
            }
            if os2.u16(0) >= 2 && os2.length >= 90 {
                xh = os2.i16(86)
                cap = os2.i16(88)
            }
        }
        weightClass = weight
        fsType = fs
        xHeight = xh
        capHeight = cap
        ascent = asc
        descent = desc

        let post = table("post")
        italicAngle = Double(post.i16(4)) + Double(post.u16(6)) / 65536.0
        isFixedPitch = post.u32(12) != 0

        if let c = tables["CFF "] {
            cff = CffFont.tryParse(data, c.offset, c.length)
        } else {
            cff = nil
        }
        readCmapDirectory()
        if capHeight == 0 { capHeight = guessCapHeight() }
    }

    /// 1 for a plain font file, the number of fonts in a collection (.ttc), 0 when the bytes are no sfnt.
    public static func collectionCount(_ data: [UInt8]) -> Int {
        if data.count < 12 { return 0 }
        let d = FontSpan(data)
        if d.tag(0) == "ttcf" { return Int(min(d.u32(8), 4096)) }
        return isSfntTag(d) ? 1 : 0
    }

    /// Opens the font at `collectionIndex` (0 for a plain file), or nil when it has no usable head and maxp.
    public static func tryParse(_ data: [UInt8], _ collectionIndex: Int = 0) -> TrueTypeFont? {
        let count = collectionCount(data)
        if count == 0 || collectionIndex < 0 || collectionIndex >= count { return nil }

        let all = FontSpan(data)
        var dir = 0
        if all.tag(0) == "ttcf" {
            dir = all.offset32(12 + 4 * collectionIndex)
            if dir <= 0 || dir > data.count - 12 || !isSfntTag(all.slice(from: dir)) { return nil }
        }

        let numTables = min(all.u16(dir + 4), (data.count - dir - 12) / 16)
        var tables: [String: (offset: Int, length: Int)] = [:]
        var i = 0
        while i < numTables {
            let e = dir + 12 + 16 * i
            i += 1
            let offset = all.offset32(e + 8)
            var length = all.offset32(e + 12)
            if offset <= 0 || offset >= data.count { continue }
            length = min(length, data.count - offset)
            let tag = all.tag(e)
            if tables[tag] == nil { tables[tag] = (offset, length) }
        }
        guard let head = tables["head"], head.length >= 54 else { return nil }
        guard let maxp = tables["maxp"], maxp.length >= 6 else { return nil }
        return TrueTypeFont(data, tables)
    }

    private static func isSfntTag(_ d: FontSpan) -> Bool {
        let v = d.u32(0)
        return v == 0x00010000 || v == 0x4F54544F || v == 0x74727565
    }

    /// True when the font has outlines this class can read.
    public var hasOutlines: Bool { cff != nil || (hasTable("glyf") && hasTable("loca")) }

    public var isCff: Bool { cff != nil }

    /// False for fonts whose license restricts embedding (fsType 0x0002) or that allow only bitmaps (0x0200)
    /// (OpenType spec, OS/2 fsType). Preview and print, and editable embedding, are allowed.
    public var embeddingAllowed: Bool { (fsType & 0x000E) != 0x0002 && (fsType & 0x0200) == 0 }

    /// False when fsType 0x0100 says the whole font must be embedded.
    public var subsettingAllowed: Bool { (fsType & 0x0100) == 0 }

    public func hasTable(_ tag: String) -> Bool {
        tables[tag] != nil
    }

    func table(_ tag: String) -> FontSpan {
        guard let t = tables[tag] else { return .empty }
        return FontSpan(data, t.offset, t.length)
    }

    /// Advance width of the glyph in font units, 0 for a glyph the font does not have.
    public func getAdvance(_ glyphId: Int) -> Int {
        if glyphId < 0 || glyphId >= glyphCount || hMetricCount == 0 { return 0 }
        return table("hmtx").u16(4 * min(glyphId, hMetricCount - 1))
    }

    /// Left side bearing of the glyph from hmtx.
    func getLeftSideBearing(_ glyphId: Int) -> Int {
        if glyphId < 0 || glyphId >= glyphCount { return 0 }
        let hmtx = table("hmtx")
        return glyphId < hMetricCount
            ? hmtx.i16(4 * glyphId + 2)
            : hmtx.i16(4 * hMetricCount + 2 * (glyphId - hMetricCount))
    }

    private func guessCapHeight() -> Int {
        let h = glyphForCodePoint(0x48)
        if h != 0, let b = getBounds(h), b.yMax > 0 { return FontBytes.toInt32(b.yMax) }
        return unitsPerEm * 7 / 10
    }

    /// Family name (name ID 1), nil when the table has none.
    public var familyName: String? { readName(1) }

    /// PostScript name (name ID 6), nil when the table has none.
    public var postScriptName: String? { readName(6) }

    private func readName(_ id: Int) -> String? {
        let name = table("name")
        let count = min(name.u16(2), (name.length - 6) / 12)
        let storage = name.u16(4)
        var best: String?
        var bestRank = 0
        var i = 0
        while i < count {
            let r = 6 + 12 * i
            i += 1
            if name.u16(r + 6) != id { continue }
            let platform = name.u16(r)
            let rank: Int
            switch platform {
            case 3 where name.u16(r + 4) == 0x409: rank = 4
            case 3: rank = 3
            case 0: rank = 2
            case 1 where name.u16(r + 4) == 0: rank = 1
            default: rank = 0
            }
            if rank <= bestRank { continue }
            let length = name.u16(r + 8)
            let start = storage + name.u16(r + 10)
            if start > name.length || length > name.length - start { continue }
            let raw = name.slice(start, length).toArray()
            best = platform == 1 ? Latin1.string(raw) : TrueTypeFont.decodeBigEndianUnicode(raw)
            bestRank = rank
        }
        return best
    }

    /// Encoding.BigEndianUnicode: a trailing odd byte and a lone surrogate read as U+FFFD.
    static func decodeBigEndianUnicode(_ raw: [UInt8]) -> String {
        var units: [UInt16] = []
        var i = 0
        while i + 1 < raw.count {
            units.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1]))
            i += 2
        }
        var text = String(decoding: units, as: UTF16.self)
        if raw.count % 2 == 1 { text.unicodeScalars.append("\u{FFFD}") }
        return text
    }
}
