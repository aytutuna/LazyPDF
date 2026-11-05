import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/CffFont.cs: a Compact Font Format program (Adobe TN 5176), bare as
// in a PDF's FontFile3 /Type1C and /CIDFontType0C or taken from the 'CFF ' table of an OpenType font. Name-keyed
// and CID-keyed fonts are both read. Charstring type 2 only; a font that breaks the format makes tryParse return
// nil. The C# catches the exceptions of a broken file; every read here is checked instead.

public final class CffFont {
    private static let maxGlyphs = 65535
    private static let maxFontDicts = 256
    static let maxDictSize = 1 << 16

    private let d: FontSpan
    private let strings: CffIndex
    private let charStrings: CffIndex
    private let charset: [Int]
    private var encoding = [Int](repeating: 0, count: 256)
    private var nameToGlyph: [String: Int]?
    private var idToGlyph: [Int: Int]?

    let globalSubrs: CffIndex
    let privates: [CffPrivate]
    let fdSelect: [UInt8]?

    /// The font name from the Name INDEX.
    public let name: String

    public let isCid: Bool

    /// The top dictionary's FontMatrix, 0.001 0 0 0.001 0 0 by default; a CID font's first font DICT adds its own, multiplied in.
    public let fontMatrix: [Double]

    public let fontBounds: GlyphBounds?

    private init(_ d: FontSpan, _ name: String, _ strings: CffIndex, _ gsubrs: CffIndex, _ charStrings: CffIndex, _ charset: [Int],
                 _ privates: [CffPrivate], _ fdSelect: [UInt8]?, _ isCid: Bool, _ matrix: [Double], _ bbox: GlyphBounds?) {
        self.d = d
        self.name = name
        self.strings = strings
        globalSubrs = gsubrs
        self.charStrings = charStrings
        self.charset = charset
        self.privates = privates
        self.fdSelect = fdSelect
        self.isCid = isCid
        fontMatrix = matrix
        fontBounds = bbox
    }

    public var glyphCount: Int { charStrings.count }

    var bytes: FontSpan { d }

    func charString(_ gid: Int) -> FontSpan {
        charStrings.item(d, gid)
    }

    public static func tryParse(_ data: [UInt8]) -> CffFont? {
        tryParse(data, 0, data.count)
    }

    /// Parses the CFF data at `offset`, `length` bytes long. The bytes are copied.
    public static func tryParse(_ data: [UInt8], _ offset: Int, _ length: Int) -> CffFont? {
        if offset < 0 || length < 4 || length > data.count - offset { return nil }
        return read(FontSpan(Array(data[offset..<offset + length])))
    }

    private static func read(_ d: FontSpan) -> CffFont? {
        if d[0] != 1 { return nil }
        let pos = d.u8(2)
        guard let names = CffIndex.tryRead(d, pos) else { return nil }
        guard let tops = CffIndex.tryRead(d, names.end) else { return nil }
        guard let strings = CffIndex.tryRead(d, tops.end) else { return nil }
        guard let gsubrs = CffIndex.tryRead(d, strings.end) else { return nil }
        if tops.count < 1 { return nil }

        let top = CffDict.parse(tops.item(d, 0))
        let charStringsAt = FontBytes.toInt32(top.number(17, 0))
        guard charStringsAt > 0, let charStrings = CffIndex.tryRead(d, charStringsAt) else { return nil }
        let glyphCount = min(charStrings.count, maxGlyphs)

        let isCid = top.has(1230)
        var privates: [CffPrivate] = []
        var fdSelect: [UInt8]?
        var cidMatrix: [Double]?
        if isCid {
            let fdArrayAt = FontBytes.toInt32(top.number(1236, 0))
            guard fdArrayAt > 0, let fdArray = CffIndex.tryRead(d, fdArrayAt) else { return nil }
            // Font DICTs may overlap, so each one is cut to a size no real one reaches.
            for i in 0..<min(fdArray.count, maxFontDicts) {
                let fontDict = CffDict.parse(head(fdArray.item(d, i)))
                if i == 0, let fdMatrix = fontDict.numbers(1207), fdMatrix.count == 6 { cidMatrix = fdMatrix }
                privates.append(CffPrivate.read(d, fontDict))
            }
            fdSelect = readFdSelect(d, FontBytes.toInt32(top.number(1237, 0)), glyphCount)
            if privates.isEmpty { return nil }
        } else {
            privates.append(CffPrivate.read(d, top))
        }

        let charset = readCharset(d, FontBytes.toInt32(top.number(15, 0)), glyphCount, isCid)
        var topMatrix: [Double]?
        if let m = top.numbers(1207), m.count == 6 { topMatrix = m }
        let matrix = combinedMatrix(topMatrix, cidMatrix)
        var bbox: GlyphBounds?
        if let b = top.numbers(5), b.count == 4 { bbox = GlyphBounds(b[0], b[1], b[2], b[3]) }
        let name = names.count > 0 ? Latin1.string(names.item(d, 0).toArray()) : ""

        let font = CffFont(d, name, strings, gsubrs, charStrings, charset, privates, fdSelect, isCid, matrix, bbox)
        if !isCid { font.readEncoding(FontBytes.toInt32(top.number(16, 0))) }
        return font
    }

    // The top DICT's matrix and a font DICT's multiply; with only one of them that one stands alone (the top one
    // defaults to 0.001, which a font DICT's matrix would otherwise scale twice).
    private static func combinedMatrix(_ top: [Double]?, _ fd: [Double]?) -> [Double] {
        guard let fd else { return top ?? [0.001, 0, 0, 0.001, 0, 0] }
        guard let top else { return fd }
        return [
            fd[0] * top[0] + fd[1] * top[2], fd[0] * top[1] + fd[1] * top[3],
            fd[2] * top[0] + fd[3] * top[2], fd[2] * top[1] + fd[3] * top[3],
            fd[4] * top[0] + fd[5] * top[2] + top[4], fd[4] * top[1] + fd[5] * top[3] + top[5],
        ]
    }

    private static func head(_ dict: FontSpan) -> FontSpan {
        dict.slice(0, min(dict.length, maxDictSize))
    }

    private static func readCharset(_ d: FontSpan, _ at: Int, _ glyphCount: Int, _ isCid: Bool) -> [Int] {
        var sids = [Int](repeating: 0, count: glyphCount)
        if at <= 2 {
            // The predefined charsets are only exact for ISOAdobe; Expert ones fall back to identity.
            var g = 1
            while g < glyphCount {
                sids[g] = at == 0 && !isCid ? min(g, 228) : g
                g += 1
            }
            return sids
        }

        let format = d.u8(at)
        var p = at + 1
        var gid = 1
        if format == 0 {
            while gid < glyphCount && p <= d.length - 2 {
                sids[gid] = d.u16(p)
                gid += 1
                p += 2
            }
        } else if format == 1 || format == 2 {
            let width = format == 1 ? 3 : 4
            while gid < glyphCount && p <= d.length - width {
                let first = d.u16(p)
                let left = format == 1 ? d.u8(p + 2) : d.u16(p + 2)
                p += width
                var i = 0
                while i <= left && gid < glyphCount {
                    sids[gid] = first + i
                    gid += 1
                    i += 1
                }
            }
        }
        return sids
    }

    private static func readFdSelect(_ d: FontSpan, _ at: Int, _ glyphCount: Int) -> [UInt8]? {
        if at <= 0 { return nil }
        var map = [UInt8](repeating: 0, count: glyphCount)
        let format = d.u8(at)
        if format == 0 {
            for g in 0..<glyphCount { map[g] = UInt8(d.u8(at + 1 + g)) }
        } else if format == 3 {
            let ranges = d.u16(at + 1)
            var p = at + 3
            var filled = 0
            var r = 0
            while r < ranges && p <= d.length - 5 {
                let first = d.u16(p)
                let fd = UInt8(d.u8(p + 2))
                let next = min(d.u16(p + 3), glyphCount)
                // Ranges ascend; one that starts inside the last is cut so that no glyph is written twice.
                var g = max(first, filled)
                while g < next {
                    map[g] = fd
                    g += 1
                }
                filled = max(filled, next)
                r += 1
                p += 3
            }
        } else {
            return nil
        }
        return map
    }

    private func readEncoding(_ at: Int) {
        if at == 0 {
            let bySid = sidToGlyph()
            for c in 0..<256 {
                let sid = StandardNames.standardEncodingSids[c]
                if sid != 0, let g = bySid[sid] { encoding[c] = g }
            }
            return
        }
        if at == 1 { return }

        let format = d.u8(at)
        var p = at + 1
        if (format & 0x7F) == 0 {
            let n = d.u8(p)
            p += 1
            var i = 0
            while i < n && p < d.length {
                encoding[d.u8(p)] = i + 1
                p += 1
                i += 1
            }
        } else if (format & 0x7F) == 1 {
            let ranges = d.u8(p)
            p += 1
            var gid = 1
            var r = 0
            while r < ranges && p <= d.length - 2 {
                let first = d.u8(p)
                var i = 0
                while i <= d.u8(p + 1) {
                    if first + i < 256 {
                        encoding[first + i] = gid
                        gid += 1
                    }
                    i += 1
                }
                r += 1
                p += 2
            }
        }
        if (format & 0x80) != 0 {
            let n = d.u8(p)
            p += 1
            let bySid = sidToGlyph()
            var i = 0
            while i < n && p <= d.length - 3 {
                if let g = bySid[d.u16(p + 1)] { encoding[d.u8(p)] = g }
                i += 1
                p += 3
            }
        }
    }

    private func sidToGlyph() -> [Int: Int] {
        if let map = idToGlyph { return map }
        var map: [Int: Int] = [:]
        for g in stride(from: charset.count - 1, through: 0, by: -1) { map[charset[g]] = g }
        idToGlyph = map
        return map
    }

    /// Glyph for a code of the font's built-in encoding (name-keyed fonts), 0 when unassigned.
    public func glyphForCode(_ code: Int) -> Int {
        code >= 0 && code < 256 ? encoding[code] : 0
    }

    /// The glyph name, nil for a CID-keyed font or a glyph out of range.
    public func glyphName(_ glyphId: Int) -> String? {
        if isCid || glyphId < 0 || glyphId >= charset.count { return nil }
        let sid = charset[glyphId]
        if sid < StandardNames.cffStrings.count { return StandardNames.cffStrings[sid] }
        let s = strings.item(d, sid - StandardNames.cffStrings.count)
        return Latin1.string(s.toArray())
    }

    /// The first glyph with this name, 0 when there is none or the font is CID-keyed.
    public func glyphForName(_ name: String) -> Int {
        if isCid { return 0 }
        if nameToGlyph == nil {
            var map: [String: Int] = [:]
            for g in 0..<charset.count {
                if let n = glyphName(g), map[n] == nil { map[n] = g }
            }
            nameToGlyph = map
        }
        return nameToGlyph?[name] ?? 0
    }

    /// Glyph for a CID. A CID-keyed font maps through its charset; a name-keyed font used as a CIDFont
    /// takes the CID as the glyph index (ISO 32000-1 9.7.4.2). 0 when absent.
    public func glyphForCid(_ cid: Int) -> Int {
        if !isCid { return cid >= 0 && cid < glyphCount ? cid : 0 }
        return sidToGlyph()[cid] ?? 0
    }

    /// The CID of a glyph in a CID-keyed font; the glyph index itself otherwise.
    public func cidForGlyph(_ glyphId: Int) -> Int {
        isCid && glyphId >= 0 && glyphId < charset.count ? charset[glyphId] : glyphId
    }

    /// Advance width of the glyph in font units, taken from its charstring. 0 for a glyph out of range.
    public func getWidth(_ glyphId: Int) -> Double {
        glyphId < 0 || glyphId >= glyphCount ? 0 : interpret(glyphId, true, true).width
    }

    /// The glyph's outline in font units (cubic curves), nil for a glyph out of range. A broken charstring gives what was drawn before it broke.
    public func getOutline(_ glyphId: Int) -> GlyphOutline? {
        glyphId < 0 || glyphId >= glyphCount ? nil : interpret(glyphId, false, true).outline
    }

    func interpret(_ glyphId: Int, _ widthOnly: Bool, _ allowSeac: Bool) -> CffGlyph {
        var fd = 0
        if let select = fdSelect, glyphId < select.count { fd = Int(select[glyphId]) }
        let priv = privates[min(fd, privates.count - 1)]
        return CffInterpreter(self, priv, widthOnly, allowSeac).run(glyphId)
    }
}

struct CffGlyph {
    let outline: GlyphOutline
    let width: Double
}

struct CffPrivate {
    let subrs: CffIndex
    let defaultWidth: Double
    let nominalWidth: Double

    /// Reads the Private DICT a font DICT points to, with its local subroutines.
    static func read(_ d: FontSpan, _ fontDict: CffDict) -> CffPrivate {
        guard let p = fontDict.numbers(18), p.count == 2, p[1] > 0, p[1] < Double(d.length) else {
            return CffPrivate(subrs: CffIndex(), defaultWidth: 0, nominalWidth: 0)
        }
        let at = FontBytes.toInt32(p[1])
        let size = FontBytes.toInt32(min(min(max(p[0], 0), Double(d.length - at)), Double(CffFont.maxDictSize)))
        let dict = CffDict.parse(d.slice(at, size))
        var subrs = CffIndex()
        let subrsAt = dict.number(19, 0)
        if subrsAt > 0 && Double(at) + subrsAt < Double(d.length) {
            subrs = CffIndex.tryRead(d, at + FontBytes.toInt32(subrsAt)) ?? CffIndex()
        }
        return CffPrivate(subrs: subrs, defaultWidth: dict.number(20, 0), nominalWidth: dict.number(21, 0))
    }
}

struct CffIndex {
    private let offsetsAt: Int
    private let offSize: Int
    private let dataBase: Int

    let count: Int

    /// Position after the INDEX, where the next structure starts.
    let end: Int

    init() {
        count = 0
        end = 0
        offsetsAt = 0
        offSize = 0
        dataBase = 0
    }

    private init(_ count: Int, _ offSize: Int, _ offsetsAt: Int, _ dataBase: Int, _ end: Int) {
        self.count = count
        self.offSize = offSize
        self.offsetsAt = offsetsAt
        self.dataBase = dataBase
        self.end = end
    }

    static func tryRead(_ d: FontSpan, _ pos: Int) -> CffIndex? {
        if pos < 0 || pos > d.length - 2 { return nil }
        let count = d.u16(pos)
        if count == 0 { return CffIndex(0, 1, pos + 2, pos + 2, pos + 2) }
        let offSize = d.u8(pos + 2)
        if offSize < 1 || offSize > 4 { return nil }
        let offsetsAt = pos + 3
        let dataBase = offsetsAt + (count + 1) * offSize - 1
        if dataBase >= d.length { return nil }
        let last = offset(d, offsetsAt, offSize, count)
        if last < 1 || last > d.length - dataBase { return nil }
        return CffIndex(count, offSize, offsetsAt, dataBase, dataBase + last)
    }

    private static func offset(_ d: FontSpan, _ at: Int, _ size: Int, _ i: Int) -> Int {
        var v = 0
        for k in 0..<size { v = (v << 8) | d.u8(at + i * size + k) }
        return v > Int(Int32.max) ? Int(Int32.max) : v
    }

    func item(_ d: FontSpan, _ i: Int) -> FontSpan {
        if i < 0 || i >= count { return .empty }
        let start = CffIndex.offset(d, offsetsAt, offSize, i)
        let stop = CffIndex.offset(d, offsetsAt, offSize, i + 1)
        if start < 1 || stop < start || stop > end - dataBase { return .empty }
        return d.slice(dataBase + start, stop - start)
    }
}

/// A parsed DICT: the operands of each operator, a two-byte operator 12 n keyed as 1200 + n.
final class CffDict {
    private static let maxOperands = 48
    private var entries: [Int: [Double]] = [:]

    static func parse(_ d: FontSpan) -> CffDict {
        let dict = CffDict()
        var operands = [Double](repeating: 0, count: maxOperands)
        var n = 0
        var p = 0
        while p < d.length {
            let b = Int(d[p])
            p += 1
            if b <= 21 {
                var op = b
                if b == 12 {
                    op = 1200 + d.u8(p)
                    p += 1
                }
                dict.entries[op] = Array(operands[0..<n])
                n = 0
                continue
            }

            let v: Double
            if b == 28 {
                v = Double(d.i16(p))
                p += 2
            } else if b == 29 {
                v = Double(Int32(truncatingIfNeeded: d.u32(p)))
                p += 4
            } else if b == 30 {
                v = readReal(d, &p)
            } else if b >= 32 && b <= 246 {
                v = Double(b - 139)
            } else if b >= 247 && b <= 250 {
                v = Double((b - 247) * 256 + d.u8(p) + 108)
                p += 1
            } else if b >= 251 && b <= 254 {
                v = Double(-(b - 251) * 256 - d.u8(p) - 108)
                p += 1
            } else {
                continue
            }
            if n < maxOperands {
                operands[n] = v
                n += 1
            }
        }
        return dict
    }

    private static func readReal(_ d: FontSpan, _ p: inout Int) -> Double {
        var text = ""
        while p < d.length {
            let b = Int(d[p])
            p += 1
            for half in 0..<2 {
                let nibble = half == 0 ? b >> 4 : b & 15
                switch nibble {
                case 0...9: text.unicodeScalars.append(Unicode.Scalar(UInt8(48 + nibble)))
                case 10: text += "."
                case 11: text += "E"
                case 12: text += "E-"
                case 14: text += "-"
                case 15: return FontBytes.parseDouble(text) ?? 0
                default: break
                }
            }
        }
        return 0
    }

    func has(_ op: Int) -> Bool {
        entries[op] != nil
    }

    func numbers(_ op: Int) -> [Double]? {
        entries[op]
    }

    func number(_ op: Int, _ fallback: Double) -> Double {
        if let v = entries[op], !v.isEmpty { return v[0] }
        return fallback
    }
}
