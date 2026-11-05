import Foundation

// Twin of windows/LazyPDF.Core/Content/PdfFontProgram.cs: the embedded font file of a font descriptor, whichever of
// the three formats it holds.

final class FontProgram {
    private static let maxSize = 64 << 20

    private var reverse: [Int: Int]?

    let trueType: TrueTypeFont?
    let bareCff: CffFont?
    let type1: Type1Font?

    private init(trueType: TrueTypeFont? = nil, bareCff: CffFont? = nil, type1: Type1Font? = nil) {
        self.trueType = trueType
        self.bareCff = bareCff
        self.type1 = type1
    }

    /// The CFF outlines of a bare CFF or an OpenType font.
    var cff: CffFont? { bareCff ?? trueType?.cff }

    static func load(_ document: PdfDocument, _ descriptor: PdfDictionary?) -> FontProgram? {
        guard let descriptor else { return nil }
        for key in ["FontFile2", "FontFile3", "FontFile"] {
            guard let stream = document.resolve(descriptor[key]) as? PdfStream else { continue }
            let data: [UInt8]
            do {
                data = try document.data(stream, maxSize)
            } catch {
                continue
            }
            if let program = parse(data) { return program }
        }
        return nil
    }

    // The key a file sits under is no guide: sniff the bytes.
    private static func parse(_ data: [UInt8]) -> FontProgram? {
        if data.count < 4 { return nil }
        let head = Array(data[0..<4])
        if head == [0, 1, 0, 0] || head == Array("true".utf8) || head == Array("OTTO".utf8) || head == Array("ttcf".utf8) {
            return TrueTypeFont.tryParse(data).map { FontProgram(trueType: $0) }
        }
        if data[0] == 1 && data[1] == 0 {
            return CffFont.tryParse(data).map { FontProgram(bareCff: $0) }
        }
        return Type1Font.tryParse(data).map { FontProgram(type1: $0) }
    }

    /// The glyph name the program's own encoding gives a code.
    func builtInName(_ code: Int) -> String? {
        if let type1 { return type1.builtInEncoding[code] }
        if let cff {
            let gid = cff.glyphForCode(code)
            return gid > 0 ? cff.glyphName(gid) : nil
        }
        return nil
    }

    /// The advance of a glyph in 1/1000 em, by name where the program has names, else by code.
    func width(_ code: Int, _ name: String?) -> Double? {
        if let t1 = type1 {
            guard let name = name ?? t1.builtInEncoding[code], t1.hasGlyph(name) else { return nil }
            return t1.getWidth(name) * t1.fontMatrix[0] * 1000
        }
        if let cff, trueType == nil {
            var gid = name.map { cff.glyphForName($0) } ?? 0
            if gid == 0 { gid = cff.glyphForCode(code) }
            return gid > 0 ? cff.getWidth(gid) * cff.fontMatrix[0] * 1000 : nil
        }
        return nil
    }

    /// The text of a TrueType glyph: the cmap read backwards, then the glyph's name in the post table.
    func unicodeOf(_ glyph: Int) -> String? {
        guard let tt = trueType else { return nil }
        let table = reverse ?? Self.reverseCmap(tt)
        reverse = table
        if let codePoint = table[glyph] {
            guard let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: codePoint)) else { return nil }
            return String(scalar)
        }
        if let name = tt.glyphName(glyph) { return GlyphList.unicodeOf(name) }
        return nil
    }

    // The private use area is where symbol fonts park their glyphs; as text it is noise.
    private static func reverseCmap(_ tt: TrueTypeFont) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for cp in 0x20...0xFFFF {
            if cp >= 0xD800 && cp <= 0xF8FF { continue }
            let glyph = tt.glyphForCodePoint(cp)
            if glyph > 0 && map[glyph] == nil { map[glyph] = cp }
        }
        return map
    }
}
