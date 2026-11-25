import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/EmbeddedFontBuilder.cs: the pieces of a Type0 font with Identity-H
// encoding (ISO 32000-1 9.7) for some text, from a font file. Plain data; the caller writes the objects. The
// subset tag is made from a SHA-256 hash, which the Crypt layer provides.

public enum EmbedStatus {
    case ok
    case unreadable
    case noOutlines
    /// OS/2 fsType restricts embedding. Nothing is built.
    case embeddingForbidden
}

/// Widths of consecutive CIDs starting at `firstCid`, in 1/1000 em: one "c [w1 w2 ...]" entry of /W.
public struct WidthRun: Equatable {
    public let firstCid: Int
    public let widths: [Int]
}

/// Values for a /FontDescriptor, in the 1/1000 em units of the PDF.
public struct FontDescriptorValues: Equatable {
    public let flags: Int
    public let fontBBox: [Int]
    public let italicAngle: Double
    public let ascent: Int
    public let descent: Int
    public let capHeight: Int
    public let stemV: Int
}

/// The pieces of a Type0 font with Identity-H encoding (ISO 32000-1 9.7) for some text. A character code is two
/// bytes, big-endian, and is also the CID.
public struct EmbeddedFont {
    /// /BaseFont and /FontName, with a six-letter subset tag when `isSubset` (9.6.4).
    public let baseFont: String
    /// False: /CIDFontType2 with the program as /FontFile2 and /CIDToGIDMap /Identity.
    /// True: /CIDFontType0 with the whole OpenType font as /FontFile3 /Subtype /OpenType; no CIDToGIDMap.
    public let isCff: Bool
    public let isSubset: Bool
    /// The font file bytes.
    public let program: [UInt8]
    /// /DW. Every code in `widths` has its own entry.
    public let defaultWidth: Int
    public let widths: [WidthRun]
    public let descriptor: FontDescriptorValues
    /// Unicode code point to character code for every character of the text the font has a glyph for.
    public let codes: [Int: Int]
    /// Code points of the text the font has no glyph for; they encode as code 0 (.notdef).
    public let missing: [Int]
    /// Glyph ID of the source font to character code, for text that was shaped into glyphs.
    public let glyphCodes: [Int: Int]
    /// Character code to the text it stands for, for the /ToUnicode CMap. One glyph may stand for several code points.
    public let unicodeOfCode: [Int: String]

    /// The string as two-byte codes for a show-text operator.
    public func encode(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf16.count * 2)
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 { continue }
            let code = codes[Int(scalar.value)] ?? 0
            bytes.append(UInt8(truncatingIfNeeded: code >> 8))
            bytes.append(UInt8(truncatingIfNeeded: code))
        }
        return bytes
    }

    /// Character code to code point, for a /ToUnicode CMap. Where two characters share a glyph the lower code point wins.
    public func toUnicode() -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (codePoint, code) in codes.sorted(by: { $0.key > $1.key }) { map[code] = codePoint }
        return map
    }
}

public enum EmbeddedFontBuilder {
    /// TrueType fonts are cut down to the glyphs of `texts` (TrueTypeSubsetter), codes are the new glyph IDs.
    /// A TrueType font whose OS/2 forbids subsetting, and any OpenType font with CFF outlines, is embedded whole
    /// with the glyph ID as code; there is no CFF subsetter. A font that forbids embedding is refused.
    /// Each character gets the glyph the cmap has for it; `buildGlyphs` takes glyphs a shaper chose.
    public static func build(_ font: [UInt8], _ texts: [String], _ collectionIndex: Int = 0) -> (font: EmbeddedFont?, status: EmbedStatus) {
        let (opened, status) = open(font, collectionIndex)
        guard let f = opened else { return (nil, status) }

        var glyphOf: [Int: Int] = [:]
        var missing: Set<Int> = []
        for text in texts {
            for scalar in text.unicodeScalars {
                let cp = Int(scalar.value)
                if cp < 0x20 || glyphOf[cp] != nil || missing.contains(cp) { continue }
                let gid = f.glyphForCodePoint(cp)
                if gid == 0 || gid >= f.glyphCount {
                    missing.insert(cp)
                } else {
                    glyphOf[cp] = gid
                }
            }
        }
        let codePoints = glyphOf.keys.sorted()

        guard let parts = assemble(font, f, codePoints.map { glyphOf[$0] ?? 0 }, collectionIndex) else { return (nil, .unreadable) }
        var codes: [Int: Int] = [:]
        for (cp, gid) in glyphOf { codes[cp] = parts.glyphCodes[gid] ?? 0 }
        var unicode: [Int: String] = [:]
        for cp in codePoints.reversed() {
            if let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: cp)), let code = codes[cp] { unicode[code] = String(scalar) }
        }
        return (finish(f, parts, codes, missing.sorted(), unicode), .ok)
    }

    /// Like `build` for glyphs a shaper chose. `unicodeOfGlyph` maps each glyph ID used to the text it stands for
    /// (several code points for a ligature); `missing` are the code points that came out as .notdef. `codes` holds
    /// the glyphs that stand for a single code point.
    public static func buildGlyphs(_ font: [UInt8], _ unicodeOfGlyph: [Int: String], _ missing: [Int], _ collectionIndex: Int = 0)
        -> (font: EmbeddedFont?, status: EmbedStatus) {
        let (opened, status) = open(font, collectionIndex)
        guard let f = opened else { return (nil, status) }

        // The order only feeds the subset tag: the subsetter numbers glyphs by ID whatever the order.
        let glyphs = unicodeOfGlyph.filter { $0.key > 0 && $0.key < f.glyphCount }.sorted { a, b in
            let fa = a.value.unicodeScalars.first.map { Int($0.value) } ?? Int.max
            let fb = b.value.unicodeScalars.first.map { Int($0.value) } ?? Int.max
            return fa != fb ? fa < fb : a.key < b.key
        }.map { $0.key }
        guard let parts = assemble(font, f, glyphs, collectionIndex) else { return (nil, .unreadable) }
        var codes: [Int: Int] = [:]
        var unicode: [Int: String] = [:]
        for gid in glyphs {
            let text = unicodeOfGlyph[gid] ?? ""
            let code = parts.glyphCodes[gid] ?? 0
            unicode[code] = text
            let scalars = text.unicodeScalars
            if scalars.count == 1, let first = scalars.first { codes[Int(first.value)] = code }
        }
        return (finish(f, parts, codes, Set(missing).sorted(), unicode), .ok)
    }

    private static func open(_ font: [UInt8], _ collectionIndex: Int) -> (TrueTypeFont?, EmbedStatus) {
        guard let f = TrueTypeFont.tryParse(font, collectionIndex) else { return (nil, .unreadable) }
        if !f.hasOutlines { return (nil, .noOutlines) }
        if !f.embeddingAllowed { return (nil, .embeddingForbidden) }
        return (f, .ok)
    }

    private struct Parts {
        let program: [UInt8]
        let whole: Bool
        let glyphCodes: [Int: Int]
        let glyphs: [Int]
    }

    private static func assemble(_ font: [UInt8], _ f: TrueTypeFont, _ glyphs: [Int], _ collectionIndex: Int) -> Parts? {
        // A collection cannot be embedded as it is: its fonts share tables by offset.
        let whole = f.isCff || !f.subsettingAllowed
        if whole && Array(font.prefix(4)) == Array("ttcf".utf8) { return nil }

        let program: [UInt8]
        var codeOf: [Int: Int] = [:]
        if whole {
            program = font
            // 9.7.4.2: the code of a CIDFontType0 is a CID, which a CID-keyed font maps through its charset.
            for gid in glyphs { codeOf[gid] = f.cff?.cidForGlyph(gid) ?? gid }
        } else {
            let result = TrueTypeSubsetter.subset(font, Set(glyphs), collectionIndex)
            if result.status != .ok { return nil }
            program = result.data
            for gid in glyphs { codeOf[gid] = result.glyphMap[gid] ?? 0 }
        }
        return Parts(program: program, whole: whole, glyphCodes: codeOf, glyphs: glyphs)
    }

    private static func finish(_ f: TrueTypeFont, _ parts: Parts, _ codes: [Int: Int], _ missing: [Int], _ unicode: [Int: String]) -> EmbeddedFont {
        var widths: [Int: Int] = [:]
        for (gid, code) in parts.glyphCodes { widths[code] = scale(Double(f.getAdvance(gid)), f.unitsPerEm) }

        // CID 0 has no glyph of the text, but Width measures a missing character by the .notdef advance.
        if !missing.isEmpty { widths[0] = scale(Double(f.getAdvance(0)), f.unitsPerEm) }

        return EmbeddedFont(
            baseFont: baseFontName(f, !parts.whole, parts.glyphs),
            isCff: f.isCff,
            isSubset: !parts.whole,
            program: parts.program,
            defaultWidth: 1000,
            widths: runs(widths),
            descriptor: describe(f),
            codes: codes,
            missing: missing,
            glyphCodes: parts.glyphCodes,
            unicodeOfCode: unicode)
    }

    private static func scale(_ units: Double, _ unitsPerEm: Int) -> Int {
        FontBytes.toInt32((units * 1000 / Double(unitsPerEm)).rounded(.toNearestOrEven))
    }

    private static func runs(_ widths: [Int: Int]) -> [WidthRun] {
        var runs: [WidthRun] = []
        var current: [Int]?
        var first = 0
        var next = -1
        for (code, width) in widths.sorted(by: { $0.key < $1.key }) {
            if current == nil || code != next {
                if let done = current { runs.append(WidthRun(firstCid: first, widths: done)) }
                current = []
                first = code
            }
            current?.append(width)
            next = code + 1
        }
        if let done = current { runs.append(WidthRun(firstCid: first, widths: done)) }
        return runs
    }

    private static func describe(_ f: TrueTypeFont) -> FontDescriptorValues {
        let u = f.unitsPerEm
        var flags = 32
        if f.isFixedPitch { flags |= 1 }
        if f.italicAngle != 0 { flags |= 64 }
        let weight = f.weightClass >= 100 && f.weightClass <= 900 ? f.weightClass : 400
        let stemV = FontBytes.toInt32(50 + pow(Double(weight) / 65.0, 2))
        let b = f.fontBounds
        return FontDescriptorValues(
            flags: flags,
            fontBBox: [scale(b.xMin, u), scale(b.yMin, u), scale(b.xMax, u), scale(b.yMax, u)],
            italicAngle: f.italicAngle,
            ascent: scale(Double(f.ascent), u),
            descent: scale(Double(f.descent), u),
            capHeight: scale(Double(f.capHeight), u),
            stemV: stemV)
    }

    private static func baseFontName(_ f: TrueTypeFont, _ subset: Bool, _ glyphs: [Int]) -> String {
        let raw = f.postScriptName ?? f.familyName ?? "Font"
        var name = ""
        for c in raw.unicodeScalars {
            let letter = (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A)
            let digit = c.value >= 0x30 && c.value <= 0x39
            if letter || digit || c == "-" || c == "_" { name.unicodeScalars.append(c) }
        }
        if name.isEmpty { name = "Font" }
        if !subset { return name }

        let seed = Array((name + ":" + glyphs.map { String($0) }.joined(separator: ",")).utf8)
        let hash = Sha256.hash(seed)
        var tag = ""
        for i in 0..<6 { tag.unicodeScalars.append(Unicode.Scalar(UInt8(65 + Int(hash[i]) % 26))) }
        return tag + "+" + name
    }
}
