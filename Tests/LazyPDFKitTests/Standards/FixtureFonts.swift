import Foundation
@testable import LazyPDFKit

// No C# twin. The C# tests read Arial, Times New Roman, Courier New and Symbol from the Windows fonts folder; these are
// TrueType fonts made here that behave as those do where the tests look. The Latin one has the 258 glyphs of the standard
// Macintosh order (so a 'post' table of format 1 names them, as NamedGlyphs in the font fix tests makes of it) and the
// glyphs of every name WinAnsi, MacRoman and StandardEncoding use, a (3,1) and a (1,0) cmap, the advances of Helvetica
// (an "H" is 722, an "i" 222) and a box for an outline. The Symbol one has the glyphs of the built-in encoding of the
// Standard 14 font, in a (3,0) cmap at 0xF000 and the code and a (1,0) one at the code, and no Unicode cmap.

enum FixtureFonts {
    private struct Glyph {
        let name: String
        let advance: Int
        let drawn: Bool
    }

    private static let lock = NSLock()
    private static var made: [String: [UInt8]] = [:]

    /// The font a FontSource would give for the family and style: the Latin one named after the family, or the symbol one.
    static func font(_ family: String, _ style: FontStyles) -> [UInt8] {
        let lowered = family.lowercased()
        if lowered == "symbol" { return symbol() }
        let base = lowered == "times new roman" ? "TimesNewRomanPS" : lowered == "courier new" ? "CourierNewPS" : "Arial"
        var suffix = ""
        if style.contains(.bold) { suffix += "Bold" }
        if style.contains(.italic) { suffix += "Italic" }
        return latin(suffix.isEmpty ? base + "MT" : base + "-" + suffix + "MT")
    }

    static var arial: [UInt8] { latin("ArialMT") }

    /// `extraGlyphs` are further glyph names to include, such as the Turkish letters no 8-bit encoding has.
    static func latin(_ postScriptName: String, extraGlyphs: [String] = []) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let key = ([postScriptName] + extraGlyphs).joined(separator: ",")
        if let known = made[key] { return known }
        let font = buildLatin(postScriptName, extraGlyphs)
        made[key] = font
        return font
    }

    static func symbol() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if let known = made["Symbol"] { return known }
        let font = buildSymbol()
        made["Symbol"] = font
        return font
    }

    // MARK: Latin

    private static let macExtras: [(name: String, code: Int)] = [
        ("notequal", 0xAD), ("infinity", 0xB0), ("lessequal", 0xB2), ("greaterequal", 0xB3), ("partialdiff", 0xB6), ("summation", 0xB7),
        ("product", 0xB8), ("pi", 0xB9), ("integral", 0xBA), ("Omega", 0xBD), ("radical", 0xC3), ("approxequal", 0xC5), ("Delta", 0xC6),
        ("lozenge", 0xD7), ("apple", 0xF0), ("Euro", 0xDB),
    ]

    private static func buildLatin(_ postScriptName: String, _ more: [String]) -> [UInt8] {
        let standard = StandardNames.macGlyphs
        var names = Array(standard.prefix(258))
        // uni01F8 is not in any encoding: a test names it in /Differences, and Arial has a glyph for it.
        var extras = Set(["uni01F8"] + more.filter { !standard.prefix(258).contains($0) })
        for table in [PdfEncodings.winAnsi, PdfEncodings.macRoman, PdfEncodings.standard] {
            for case let name? in table where !names.contains(name) { extras.insert(name) }
        }
        for extra in macExtras where !names.contains(extra.name) { extras.insert(extra.name) }
        names += extras.sorted()

        let helvetica = Standard14.find("Helvetica")
        var glyphs: [Glyph] = []
        var gid: [String: Int] = [:]
        var unicode: [Int: Int] = [:]
        for (i, name) in names.enumerated() {
            let text = GlyphList.unicodeOf(name)
            let scalars = text.map { Array($0.unicodeScalars) } ?? []
            let blank = scalars.count == 1 && scalars[0].properties.isWhitespace
            let advance: Int
            switch name {
            case ".notdef": advance = 750
            case ".null", "nonmarkingreturn": advance = 0
            default: advance = helvetica?.widthOf(name) ?? 600
            }
            glyphs.append(Glyph(name: name, advance: advance, drawn: !(name == ".null" || name == "nonmarkingreturn" || blank)))
            if gid[name] == nil { gid[name] = i }
            if scalars.count == 1, scalars[0].value <= 0xFFFF, unicode[Int(scalars[0].value)] == nil { unicode[Int(scalars[0].value)] = i }
        }

        var mac = [UInt8](repeating: 0, count: 256)
        for code in 0..<256 {
            var name = PdfEncodings.macRoman[code]
            if name == nil { name = macExtras.first { $0.code == code }?.name }
            if let name, let found = gid[name], found <= 255 { mac[code] = UInt8(found) }
        }
        // Glyph numbers past 255 do not fit a format 0 subtable: the names that need them are left out of the Mac map.
        let cmap = cmapTable([(1, 0, format0(mac)), (3, 1, format4(unicode))])

        var post = u32(0x00020000) + [UInt8](repeating: 0, count: 28)
        post += u16(names.count)
        var custom: [UInt8] = []
        var customCount = 0
        for (i, name) in names.enumerated() {
            if i < 258 {
                post += u16(i)
            } else {
                post += u16(258 + customCount)
                customCount += 1
                let bytes = Array(name.utf8)
                custom.append(UInt8(bytes.count))
                custom += bytes
            }
        }
        post += custom
        return assemble(glyphs, cmap, post, postScriptName, "Arial")
    }

    // MARK: Symbol

    private static func buildSymbol() -> [UInt8] {
        let encoding = Standard14.find("Symbol")?.builtInEncoding ?? []
        var glyphs = [Glyph(name: ".notdef", advance: 600, drawn: true)]
        var gid: [String: Int] = [:]
        var symbol: [Int: Int] = [:]
        var mac = [UInt8](repeating: 0, count: 256)
        for code in 32..<min(256, encoding.count) {
            guard let name = encoding[code] else { continue }
            if gid[name] == nil {
                gid[name] = glyphs.count
                glyphs.append(Glyph(name: name, advance: Standard14.find("Symbol")?.widthOf(name) ?? 600, drawn: true))
            }
            symbol[0xF000 + code] = gid[name]
            if let found = gid[name], found <= 255 { mac[code] = UInt8(found) }
        }
        // The Windows file has a Macintosh subtable as well, which sends a code to the glyph of the same code.
        let cmap = cmapTable([(1, 0, format0(mac)), (3, 0, format4(symbol))])
        let post = u32(0x00030000) + [UInt8](repeating: 0, count: 28)
        return assemble(glyphs, cmap, post, "Symbol", "Symbol")
    }

    // MARK: Tables

    private static func u16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }

    private static func u32(_ value: Int) -> [UInt8] { u16(value >> 16) + u16(value) }

    private static func format0(_ glyphs: [UInt8]) -> [UInt8] { u16(0) + u16(262) + u16(0) + glyphs }

    private static func format4(_ map: [Int: Int]) -> [UInt8] {
        let codes = map.keys.sorted()
        let segments = codes.count + 1
        var entrySelector = 0
        while (1 << (entrySelector + 1)) <= segments { entrySelector += 1 }
        let searchRange = 2 * (1 << entrySelector)
        var table = u16(4) + u16(16 + 8 * segments) + u16(0) + u16(2 * segments) + u16(searchRange) + u16(entrySelector) + u16(2 * segments - searchRange)
        for code in codes { table += u16(code) }
        table += u16(0xFFFF) + u16(0)
        for code in codes { table += u16(code) }
        table += u16(0xFFFF)
        for code in codes { table += u16((map[code] ?? 0) - code) }
        table += u16(1)
        table += [UInt8](repeating: 0, count: 2 * segments)
        return table
    }

    private static func cmapTable(_ subtables: [(platform: Int, encoding: Int, data: [UInt8])]) -> [UInt8] {
        var table = u16(0) + u16(subtables.count)
        var offset = 4 + 8 * subtables.count
        for subtable in subtables {
            table += u16(subtable.platform) + u16(subtable.encoding) + u32(offset)
            offset += subtable.data.count
        }
        for subtable in subtables { table += subtable.data }
        return table
    }

    private static func nameTable(_ family: String, _ postScript: String) -> [UInt8] {
        let strings = [(1, Sfnt.utf16(family)), (6, Sfnt.utf16(postScript))]
        var table = u16(0) + u16(strings.count) + u16(6 + 12 * strings.count)
        var storage: [UInt8] = []
        for (id, text) in strings {
            table += u16(3) + u16(1) + u16(0x409) + u16(id) + u16(text.count) + u16(storage.count)
            storage += text
        }
        return table + storage
    }

    private static func assemble(_ glyphs: [Glyph], _ cmap: [UInt8], _ post: [UInt8], _ postScriptName: String, _ family: String) -> [UInt8] {
        var glyf: [UInt8] = []
        var loca: [UInt8] = []
        var hmtx: [UInt8] = []
        for glyph in glyphs {
            loca += u16(glyf.count / 2)
            var leftBearing = 0
            if glyph.drawn {
                let left = 50, right = Swift.max(glyph.advance - 50, 100), top = 700
                leftBearing = left
                var data = u16(1) + u16(left) + u16(0) + u16(right) + u16(top)
                data += u16(3) + u16(0)
                data += [1, 1, 1, 1]
                data += u16(left) + u16(0) + u16(right - left) + u16(0)
                data += u16(0) + u16(top) + u16(0) + u16(-top)
                while data.count % 4 != 0 { data.append(0) }
                glyf += data
            }
            hmtx += u16(glyph.advance) + u16(leftBearing)
        }
        loca += u16(glyf.count / 2)

        var head = u32(0x00010000) + u32(0x00010000) + u32(0) + u32(0x5F0F3CF5) + u16(0) + u16(1000)
        head += [UInt8](repeating: 0, count: 16)
        head += u16(0) + u16(-250) + u16(1100) + u16(950) + u16(0) + u16(8) + u16(2) + u16(0) + u16(0)

        var hhea = u32(0x00010000) + u16(905) + u16(-212) + u16(0) + u16(1100) + u16(0) + u16(0) + u16(1100)
        hhea += u16(1) + u16(0) + u16(0) + [UInt8](repeating: 0, count: 8) + u16(0) + u16(glyphs.count)

        let maxp = u32(0x00010000) + u16(glyphs.count) + u16(4) + u16(1) + [UInt8](repeating: 0, count: 22)

        var os2 = [UInt8](repeating: 0, count: 96)
        func put(_ at: Int, _ value: Int) {
            os2[at] = UInt8((value >> 8) & 0xFF)
            os2[at + 1] = UInt8(value & 0xFF)
        }
        put(0, 2)
        put(4, 400)
        put(6, 5)
        put(86, 519)
        put(88, 716)

        let tables: [Sfnt.Table] = [
            ("OS/2", os2), ("cmap", cmap), ("glyf", glyf), ("head", head), ("hhea", hhea), ("hmtx", hmtx), ("loca", loca),
            ("maxp", maxp), ("name", nameTable(family, postScriptName)), ("post", post),
        ]
        return Sfnt.build([tables])
    }
}

/// The C# SystemFonts: Arial, Times New Roman, Courier New and Symbol from the Windows fonts folder; anything else gets Arial. Here the
/// fonts are the ones above, and none of the tests that need a font is skipped for want of one.
final class SystemFonts: FontSource {
    func find(_ family: String, _ style: FontStyles) -> FontFile? {
        FontFile(FixtureFonts.font(family, style))
    }
}
