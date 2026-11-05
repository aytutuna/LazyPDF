import Foundation

// Twin of windows/LazyPDF.Core/Ocr/GlyphlessFont.cs, from Lazy Scan's GlyphlessFont: the font of the invisible text
// layer, a TrueType program whose only glyph draws nothing and is half an em wide, embedded as an Identity-H composite
// font in which every code shows that glyph. A character of the Basic Multilingual Plane is its own UTF-16 code unit;
// one beyond it gets a code in the surrogate range, which never stands for a character alone (`GlyphlessCodes`). The
// ToUnicode map gives the text back, so any script can be written, selected and searched without a font installed
// anywhere. Built from code, the same bytes on every run.

enum GlyphlessFont {
    /// The font's name, in the PDF (/BaseFont, /FontName) and in its name table.
    static let fontName = "GlyphLessFont"

    /// Units per em of the font program.
    static let unitsPerEm = 1000

    /// The advance of every glyph, in 1/1000 em: the PDF's /DW and the program's hmtx agree.
    static let glyphWidth = 500

    /// Character codes: 0 to this (two bytes).
    static let codeCount = 0x10000

    /// The TrueType program (/FontFile2), built once.
    static let program = build()

    /// The /CIDToGIDMap stream's data, zlib-compressed (/Filter /FlateDecode): every code to glyph 1, so no code ever
    /// shows the .notdef glyph. Built once.
    static let cidToGidMap = buildCidToGidMap()

    /// A TrueType font with two glyphs, both empty: .notdef and glyph 1, each 500 units wide on a 1000-unit em, ascent
    /// 1000 and descent 0 (so a line's text fills its box from the baseline up). Tables: OS/2, cmap (U+0020 to glyph 1),
    /// glyf, head, hhea, hmtx, loca, maxp, name and post, with their checksums and the head's checksum adjustment.
    static func build() -> [UInt8] {
        // In the order of the tags compared as bytes.
        let tables: [(tag: String, data: [UInt8])] = [
            ("OS/2", os2Table()),
            ("cmap", cmapTable()),
            ("glyf", [UInt8](repeating: 0, count: 4)), // both glyphs are empty (loca gives them no bytes); kept non-empty for strict readers
            ("head", headTable()),
            ("hhea", hheaTable()),
            ("hmtx", hmtxTable()),
            ("loca", locaTable()),
            ("maxp", maxpTable()),
            ("name", nameTable()),
            ("post", postTable()),
        ]

        let numTables = tables.count
        var searchPower = 1
        var entrySelector = 0
        while searchPower * 2 <= numTables {
            searchPower *= 2
            entrySelector += 1
        }
        let font = BigEndianWriter()
        font.u32(0x00010000)
        font.u16(numTables)
        font.u16(searchPower * 16)
        font.u16(entrySelector)
        font.u16(numTables * 16 - searchPower * 16)

        var offset = 12 + numTables * 16
        var layout: [[UInt8]] = []
        var headOffset = 0
        for (tag, data) in tables {
            font.ascii(tag)
            font.u32(checksum(data))
            font.u32(UInt32(truncatingIfNeeded: offset))
            font.u32(UInt32(truncatingIfNeeded: data.count))
            if tag == "head" { headOffset = offset }
            layout.append(data)
            offset += padded(data.count)
        }
        for data in layout {
            font.bytes(data)
            font.bytes([UInt8](repeating: 0, count: padded(data.count) - data.count))
        }
        var bytes = font.toArray()
        // head.checkSumAdjustment (bytes 8-11 of the table) makes the whole file sum to 0xB1B0AFBA.
        let adjustment = 0xB1B0AFBA &- checksum(bytes)
        bytes[headOffset + 8] = UInt8(truncatingIfNeeded: adjustment >> 24)
        bytes[headOffset + 9] = UInt8(truncatingIfNeeded: adjustment >> 16)
        bytes[headOffset + 10] = UInt8(truncatingIfNeeded: adjustment >> 8)
        bytes[headOffset + 11] = UInt8(truncatingIfNeeded: adjustment)
        return bytes
    }

    private static func padded(_ length: Int) -> Int { (length + 3) & ~3 }

    /// The TrueType table checksum: the sum of its big-endian 32-bit words, zero-padded.
    static func checksum(_ data: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var i = 0
        while i < data.count {
            var word: UInt32 = 0
            for j in 0..<4 { word = (word &<< 8) | (i + j < data.count ? UInt32(data[i + j]) : 0) }
            sum = sum &+ word
            i += 4
        }
        return sum
    }

    private static func os2Table() -> [UInt8] {
        let t = BigEndianWriter()
        t.u16(4)                 // version
        t.i16(glyphWidth)        // xAvgCharWidth
        t.u16(400)               // usWeightClass: regular
        t.u16(5)                 // usWidthClass: medium
        t.u16(0)                 // fsType: installable, no embedding restrictions
        t.i16(650); t.i16(600); t.i16(0); t.i16(75)   // subscript x size, y size, x offset, y offset
        t.i16(650); t.i16(600); t.i16(0); t.i16(350)  // superscript x size, y size, x offset, y offset
        t.i16(50); t.i16(250)    // strikeout size, position
        t.i16(0)                 // sFamilyClass
        t.bytes([UInt8](repeating: 0, count: 10))     // panose: any
        t.u32(0); t.u32(0); t.u32(0); t.u32(0)        // ulUnicodeRange1-4
        t.ascii("NONE")          // achVendID
        t.u16(0x0040)            // fsSelection: regular
        t.u16(0x0020)            // usFirstCharIndex
        t.u16(0x0020)            // usLastCharIndex
        t.i16(unitsPerEm); t.i16(0); t.i16(0)         // typo ascender, descender, line gap
        t.u16(unitsPerEm); t.u16(0)                   // win ascent, descent
        t.u32(1); t.u32(0)       // ulCodePageRange1-2: Latin 1
        t.i16(500); t.i16(unitsPerEm)                 // sxHeight, sCapHeight
        t.u16(0); t.u16(0x0020); t.u16(1)             // usDefaultChar, usBreakChar, usMaxContext
        return t.toArray()
    }

    private static func cmapTable() -> [UInt8] {
        // One Windows Unicode (3, 1) subtable, format 4: U+0020 to glyph 1, then the required 0xFFFF segment. A PDF
        // reaches the glyph through the CIDToGIDMap, never through this.
        let t = BigEndianWriter()
        t.u16(0)   // version
        t.u16(1)   // one encoding record
        t.u16(3); t.u16(1); t.u32(12)
        let segCount = 2
        t.u16(4)                       // format
        t.u16(16 + segCount * 8)       // length
        t.u16(0)                       // language
        t.u16(segCount * 2)            // segCountX2
        t.u16(2 * 2)                   // searchRange: 2 x 2^floor(log2(segCount))
        t.u16(1)                       // entrySelector
        t.u16(0)                       // rangeShift
        t.u16(0x0020); t.u16(0xFFFF)   // endCode
        t.u16(0)                       // reservedPad
        t.u16(0x0020); t.u16(0xFFFF)   // startCode
        t.i16(1 - 0x0020); t.i16(1)    // idDelta
        t.u16(0); t.u16(0)             // idRangeOffset
        return t.toArray()
    }

    private static func headTable() -> [UInt8] {
        let t = BigEndianWriter()
        t.u32(0x00010000)        // version 1.0
        t.u32(0x00010000)        // fontRevision 1.0
        t.u32(0)                 // checkSumAdjustment: set once the whole font is laid out
        t.u32(0x5F0F3CF5)        // magicNumber
        t.u16(0x000B)            // flags: baseline at y = 0, left sidebearing at x = 0, integer scaling
        t.u16(unitsPerEm)
        t.u32(0); t.u32(0)       // created: fixed, so the bytes never change
        t.u32(0); t.u32(0)       // modified
        t.i16(0); t.i16(0); t.i16(glyphWidth); t.i16(unitsPerEm) // xMin, yMin, xMax, yMax
        t.u16(0)                 // macStyle
        t.u16(8)                 // lowestRecPPEM
        t.i16(2)                 // fontDirectionHint
        t.i16(0)                 // indexToLocFormat: short offsets
        t.i16(0)                 // glyphDataFormat
        return t.toArray()
    }

    private static func hheaTable() -> [UInt8] {
        let t = BigEndianWriter()
        t.u32(0x00010000)
        t.i16(unitsPerEm)        // ascender
        t.i16(0)                 // descender
        t.i16(0)                 // lineGap
        t.u16(glyphWidth)        // advanceWidthMax
        t.i16(0); t.i16(0)       // minLeftSideBearing, minRightSideBearing
        t.i16(0)                 // xMaxExtent
        t.i16(1); t.i16(0); t.i16(0) // caretSlopeRise, caretSlopeRun, caretOffset
        t.i16(0); t.i16(0); t.i16(0); t.i16(0) // reserved
        t.i16(0)                 // metricDataFormat
        t.u16(2)                 // numberOfHMetrics
        return t.toArray()
    }

    private static func hmtxTable() -> [UInt8] {
        let t = BigEndianWriter()
        for _ in 0..<2 {
            t.u16(glyphWidth)
            t.i16(0)
        }
        return t.toArray()
    }

    private static func locaTable() -> [UInt8] {
        let t = BigEndianWriter()
        for _ in 0..<3 { t.u16(0) } // short offsets (bytes / 2): both glyphs empty
        return t.toArray()
    }

    private static func maxpTable() -> [UInt8] {
        let t = BigEndianWriter()
        t.u32(0x00010000)        // version 1.0 (TrueType outlines)
        t.u16(2)                 // numGlyphs
        t.u16(0); t.u16(0)       // maxPoints, maxContours
        t.u16(0); t.u16(0)       // maxCompositePoints, maxCompositeContours
        t.u16(2)                 // maxZones
        t.u16(0); t.u16(0); t.u16(0); t.u16(0) // twilight points, storage, function defs, instruction defs
        t.u16(0); t.u16(0)       // maxStackElements, maxSizeOfInstructions
        t.u16(0); t.u16(0)       // maxComponentElements, maxComponentDepth
        return t.toArray()
    }

    private static func nameTable() -> [UInt8] {
        let names: [(id: Int, text: String)] = [(1, fontName), (2, "Regular"), (4, fontName), (6, fontName)]
        let strings = BigEndianWriter()
        let records = BigEndianWriter()
        for (id, text) in names {
            let utf16 = BigEndianWriter()
            for unit in text.utf16 { utf16.u16(Int(unit)) }
            records.u16(3); records.u16(1); records.u16(0x0409); records.u16(id)
            records.u16(utf16.length)
            records.u16(strings.length)
            strings.bytes(utf16.toArray())
        }
        let t = BigEndianWriter()
        t.u16(0)                         // format
        t.u16(names.count)
        t.u16(6 + names.count * 12)      // string storage offset
        t.bytes(records.toArray())
        t.bytes(strings.toArray())
        return t.toArray()
    }

    private static func postTable() -> [UInt8] {
        let t = BigEndianWriter()
        t.u32(0x00030000)        // format 3: no glyph names
        t.u32(0)                 // italicAngle
        t.i16(-100); t.i16(50)   // underlinePosition, underlineThickness
        t.u32(1)                 // isFixedPitch
        t.u32(0); t.u32(0); t.u32(0); t.u32(0) // memory hints
        return t.toArray()
    }

    /// The map's uncompressed data: two bytes per code, each the glyph 0x0001.
    static func cidToGidMapData() -> [UInt8] {
        var data = [UInt8](repeating: 0, count: codeCount * 2)
        for i in stride(from: 1, to: data.count, by: 2) { data[i] = 1 }
        return data
    }

    /// The map zlib-compressed by hand: one fixed-Huffman deflate block holding the literals 00 01, then back-references
    /// of 258 bytes at distance 2 (and one of 6) for the rest, the end of block, and the Adler-32 of the data. About 830
    /// bytes for 128 KiB, the same on every platform, with no compression library involved.
    private static func buildCidToGidMap() -> [UInt8] {
        let bits = DeflateBits()
        bits.bits(1, 1)              // BFINAL
        bits.bits(1, 2)              // BTYPE 01: fixed Huffman codes
        bits.literal(0x00)
        bits.literal(0x01)
        let remaining = codeCount * 2 - 2     // 131070 = 508 x 258 + 6
        for _ in 0..<(remaining / 258) { bits.match(258, distance: 2) }
        if remaining % 258 > 0 { bits.match(remaining % 258, distance: 2) }
        bits.endOfBlock()

        var output: [UInt8] = [0x78, 0x01] // zlib: deflate, 32 KiB window, no dictionary
        output += bits.toArray()
        let adler = adler32(cidToGidMapData())
        output += [UInt8(truncatingIfNeeded: adler >> 24), UInt8(truncatingIfNeeded: adler >> 16),
                   UInt8(truncatingIfNeeded: adler >> 8), UInt8(truncatingIfNeeded: adler)]
        return output
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        let mod: UInt32 = 65521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for value in data {
            a = (a + UInt32(value)) % mod
            b = (b + a) % mod
        }
        return (b &<< 16) | a
    }

    /// Deflate's bit order: fields least significant bit first, Huffman codes most significant bit first.
    private final class DeflateBits {
        private var bytes: [UInt8] = []
        private var current = 0
        private var count = 0

        func bits(_ value: Int, _ n: Int) {
            for i in 0..<n {
                current |= ((value >> i) & 1) << count
                count += 1
                if count == 8 {
                    bytes.append(UInt8(truncatingIfNeeded: current))
                    current = 0
                    count = 0
                }
            }
        }

        private func code(_ code: Int, _ length: Int) {
            for i in stride(from: length - 1, through: 0, by: -1) { bits((code >> i) & 1, 1) }
        }

        /// Literals 0-143 are the 8-bit codes 0x30 + value.
        func literal(_ value: Int) { code(0x30 + value, 8) }

        func endOfBlock() { code(0, 7) } // symbol 256: 7-bit code 0

        /// A length of 3-10 or 258 (symbols 257-264 and 285; no extra bits) at a distance of 1-4.
        func match(_ length: Int, distance: Int) {
            if length == 258 {
                code(0xC0 + (285 - 280), 8)           // symbols 280-287: 8-bit codes 0xC0 +
            } else if length >= 3 && length <= 10 {
                code(length - 3 + 1, 7)               // symbols 257-264: 7-bit codes 1-8
            } else {
                preconditionFailure("length")
            }
            precondition(distance >= 1 && distance <= 4, "distance")
            code(distance - 1, 5)                     // distance codes 0-3: no extra bits
        }

        func toArray() -> [UInt8] {
            var result = bytes
            if count > 0 { result.append(UInt8(truncatingIfNeeded: current)) }
            return result
        }
    }

    /// The part of every ToUnicode map that never changes: each code outside the surrogate range D800-DFFF maps to the
    /// same UTF-16 code unit, as 248 ranges of 256 codes (<XX00> <XXFF> <XX00>) in blocks of at most 100, as CMaps require.
    static let identityRanges: String = {
        let highBytes = (0..<256).filter { $0 < 0xD8 || $0 > 0xDF }
        var sb = ""
        for start in stride(from: 0, to: highBytes.count, by: 100) {
            let count = min(100, highBytes.count - start)
            sb += "\(count) beginbfrange\n"
            for high in highBytes[start..<(start + count)] {
                let h = String(format: "%02lX", high)
                sb += "<\(h)00> <\(h)FF> <\(h)00>\n"
            }
            sb += "endbfrange\n"
        }
        return sb
    }()

    private final class BigEndianWriter {
        private var data: [UInt8] = []
        var length: Int { data.count }

        func u16(_ value: Int) {
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }

        func i16(_ value: Int) { u16(value & 0xFFFF) }

        func u32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value >> 24))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }

        func ascii(_ text: String) { data += Array(text.utf8) }

        func bytes(_ bytes: [UInt8]) { data += bytes }

        func toArray() -> [UInt8] { data }
    }
}

/// The character codes of one font. A character beyond the BMP gets a code from D800 up in the order it is first used;
/// more than 2048 of them, and any lone surrogate, are written as U+FFFD (a Swift string holds no lone surrogate, so
/// one reaches `GlyphlessCodes` already as U+FFFD).
final class GlyphlessCodes {
    /// The first code given to a character beyond the Basic Multilingual Plane.
    static let firstSupplementaryCode = 0xD800

    /// How many such characters a document can carry: the surrogate range, D800-DFFF.
    static let supplementaryCapacity = 0x800

    /// What a character without a code is written as.
    static let replacementCode = 0xFFFD

    private var byCodePoint: [Int: Int] = [:]
    private(set) var supplementary: [Int] = []

    /// The codes for these texts: every character beyond the BMP in them, in order of first use.
    static func `for`(_ texts: [String]) -> GlyphlessCodes {
        let result = GlyphlessCodes()
        for text in texts {
            for scalar in text.unicodeScalars where scalar.value > 0xFFFF {
                let codePoint = Int(scalar.value)
                if result.byCodePoint[codePoint] != nil || result.supplementary.count == supplementaryCapacity { continue }
                result.byCodePoint[codePoint] = firstSupplementaryCode + result.supplementary.count
                result.supplementary.append(codePoint)
            }
        }
        return result
    }

    /// The codes an embedded font already has, read back through its ToUnicode map.
    static func from(_ font: PdfFont) -> GlyphlessCodes {
        let result = GlyphlessCodes()
        for i in 0..<supplementaryCapacity {
            let code = firstSupplementaryCode + i
            let text = font.toText([UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)])
            let scalars = Array(text.unicodeScalars)
            guard scalars.count == 1, let scalar = scalars.first, scalar.value > 0xFFFF else { break }
            result.byCodePoint[Int(scalar.value)] = code
            result.supplementary.append(Int(scalar.value))
        }
        return result
    }

    /// True when every character of `text` has a code of its own.
    func covers(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.value > 0xFFFF {
            if byCodePoint[Int(scalar.value)] == nil { return false }
        }
        return true
    }

    /// The codes of `text`, one per character.
    func codes(_ text: String) -> [Int] {
        text.unicodeScalars.map { scalar in
            scalar.value > 0xFFFF ? byCodePoint[Int(scalar.value)] ?? Self.replacementCode : Int(scalar.value)
        }
    }

    /// The string operand for `text`: two bytes per code.
    func bytes(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for code in codes(text) {
            bytes.append(UInt8(truncatingIfNeeded: code >> 8))
            bytes.append(UInt8(truncatingIfNeeded: code))
        }
        return bytes
    }

    /// The ToUnicode CMap: every code outside D800-DFFF is the UTF-16 code unit it was written from
    /// (`GlyphlessFont.identityRanges`), and each code from D800 is its character's surrogate pair, in blocks of at most 100.
    func toUnicodeCMap() -> String {
        var sb = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        sb += "/CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) /Supplement 0>> def\n"
        sb += "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
        sb += "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        sb += GlyphlessFont.identityRanges
        for start in stride(from: 0, to: supplementary.count, by: 100) {
            let count = min(100, supplementary.count - start)
            sb += "\(count) beginbfchar\n"
            for i in start..<(start + count) {
                let offset = supplementary[i] - 0x10000
                let high = 0xD800 + (offset >> 10), low = 0xDC00 + (offset & 0x3FF)
                sb += "<" + String(format: "%04lX", Self.firstSupplementaryCode + i) + "> <"
                    + String(format: "%04lX%04lX", high, low) + ">\n"
            }
            sb += "endbfchar\n"
        }
        sb += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return sb
    }
}
