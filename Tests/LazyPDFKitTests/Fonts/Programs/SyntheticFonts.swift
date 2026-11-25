import Foundation
@testable import LazyPDFKit

// No C# twin. Takes the font file of the golden tests apart and puts it together again, so that the tests can
// reach what no installed font is sure to have: a collection, an OpenType font with CFF outlines, a long loca.

enum Sfnt {
    typealias Table = (tag: String, data: [UInt8])

    static func tables(_ font: [UInt8]) -> [Table] {
        let all = FontSpan(font)
        return (0..<all.u16(4)).map { i in
            let at = 12 + 16 * i
            let offset = Int(all.u32(at + 8))
            let length = Int(all.u32(at + 12))
            return (all.tag(at), Array(font[offset..<offset + length]))
        }
    }

    static func data(_ tables: [Table], _ tag: String) -> [UInt8] {
        tables.first { $0.tag == tag }?.data ?? []
    }

    static func replacing(_ tables: [Table], _ tag: String, _ data: [UInt8]) -> [Table] {
        tables.map { $0.tag == tag ? (tag, data) : $0 }
    }

    static func without(_ tables: [Table], _ tags: [String]) -> [Table] {
        tables.filter { !tags.contains($0.tag) }
    }

    static func replacing(_ bytes: [UInt8], _ old: [UInt8], _ new: [UInt8]) -> [UInt8] {
        var i = 0
        while i + old.count <= bytes.count {
            if Array(bytes[i..<i + old.count]) == old { return Array(bytes[..<i]) + new + Array(bytes[(i + old.count)...]) }
            i += 1
        }
        return bytes
    }

    /// A font file; with `collection` a .ttc whose members are `members`, whose table offsets lie in the file.
    static func build(_ members: [[Table]], collection: Bool = false, version: UInt32 = 0x00010000) -> [UInt8] {
        var at = collection ? 12 + 4 * members.count : 0
        var dirAt: [Int] = []
        for m in members {
            dirAt.append(at)
            at += 12 + 16 * m.count
        }

        var file = [UInt8](repeating: 0, count: at)
        if collection {
            for (k, letter) in "ttcf".utf8.enumerated() { file[k] = letter }
            FontBytes.putU32(&file, 4, 0x00010000)
            FontBytes.putU32(&file, 8, UInt32(members.count))
            for (k, d) in dirAt.enumerated() { FontBytes.putU32(&file, 12 + 4 * k, UInt32(d)) }
        }
        var body: [UInt8] = []
        for (k, m) in members.enumerated() {
            let d = dirAt[k]
            FontBytes.putU32(&file, d, version)
            FontBytes.putU16(&file, d + 4, m.count)
            for (j, t) in m.enumerated() {
                let r = d + 12 + 16 * j
                for (c, letter) in t.tag.utf8.enumerated() { file[r + c] = letter }
                FontBytes.putU32(&file, r + 8, UInt32(file.count + body.count))
                FontBytes.putU32(&file, r + 12, UInt32(t.data.count))
                body += t.data
                while body.count % 4 != 0 { body.append(0) }
            }
        }
        return file + body
    }

    static func utf16(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
}

enum SyntheticFonts {
    static func ttf() throws -> [UInt8] {
        try ProgramsGolden.fixture("synthetic.ttf")
    }

    /// The same font with a cmap that maps only A, for the fallback tests: every other letter is missing from it.
    static func onlyA() throws -> [UInt8] {
        let cmap: [UInt8] = [0, 0, 0, 1, 0, 3, 0, 1, 0, 0, 0, 12,
                             0, 4, 0, 32, 0, 0, 0, 4, 0, 4, 0, 1, 0, 0,
                             0, 0x41, 0xFF, 0xFF, 0, 0, 0, 0x41, 0xFF, 0xFF, 0xFF, 0xC0, 0, 1, 0, 0, 0, 0]
        return Sfnt.build([Sfnt.replacing(Sfnt.tables(try ttf()), "cmap", cmap)])
    }

    private static func withFsType(_ tables: [Sfnt.Table], _ fsType: Int) -> [Sfnt.Table] {
        var os2 = Sfnt.data(tables, "OS/2")
        FontBytes.putU16(&os2, 8, fsType)
        return Sfnt.replacing(tables, "OS/2", os2)
    }

    /// Two members of the same tables; the second is named TestSans-Oblique. `whole` sets fsType 0x100 in both.
    static func collection(whole: Bool = false) throws -> [UInt8] {
        var first = Sfnt.tables(try ttf())
        if whole { first = withFsType(first, 0x100) }
        let second = Sfnt.replacing(first, "name", Sfnt.replacing(Sfnt.data(first, "name"), Sfnt.utf16("Regular"), Sfnt.utf16("Oblique")))
        return Sfnt.build([first, second], collection: true)
    }

    /// The cmap, metrics and names of the synthetic font around the CFF outlines of the CFF builder; no post table, so the glyph names are the CFF ones.
    static func openType(_ cff: [UInt8]) throws -> [UInt8] {
        var tables = Sfnt.without(Sfnt.tables(try ttf()), ["glyf", "loca", "cvt ", "fpgm", "prep", "post"])
        var maxp = Sfnt.data(tables, "maxp")
        FontBytes.putU16(&maxp, 4, 4)
        tables = Sfnt.replacing(tables, "maxp", maxp)
        tables.append(("CFF ", cff))
        return Sfnt.build([tables], version: 0x4F54544F)
    }

    private static func withLongLoca(_ tables: [Sfnt.Table], _ glyf: [UInt8], _ loca: [UInt8]) -> [Sfnt.Table] {
        var head = Sfnt.data(tables, "head")
        FontBytes.putU16(&head, 50, 1)
        return Sfnt.replacing(Sfnt.replacing(Sfnt.replacing(tables, "head", head), "glyf", glyf), "loca", loca)
    }

    /// The synthetic glyphs behind a long loca, with 0x20000 bytes of padding after glyph 1.
    static func longLoca() throws -> [UInt8] {
        let tables = Sfnt.tables(try ttf())
        let glyf = Sfnt.data(tables, "glyf")
        let old = FontSpan(Sfnt.data(tables, "loca"))
        var padded: [UInt8] = []
        var loca = [UInt8](repeating: 0, count: 4 * 8)
        for g in 0..<7 {
            FontBytes.putU32(&loca, 4 * g, UInt32(padded.count))
            padded += glyf[old.u16(2 * g) * 2..<old.u16(2 * g + 2) * 2]
            if g == 1 { padded += [UInt8](repeating: 0, count: 0x20000) }
        }
        FontBytes.putU32(&loca, 28, UInt32(padded.count))
        return Sfnt.build([withLongLoca(tables, padded, loca)])
    }

    /// 65535 glyphs, the even ones each 70000 bytes long (the odd ones empty): the glyphs that a subset of all of
    /// them copies add up to more than an Int32 holds, from a file of about 330 KB.
    static func hugeGlyphs() throws -> [UInt8] {
        let tables = Sfnt.tables(try ttf())
        var loca = [UInt8](repeating: 0, count: 4 * 65536)
        for k in stride(from: 1, to: 65536, by: 2) { FontBytes.putU32(&loca, 4 * k, 70000) }
        var maxp = Sfnt.data(tables, "maxp")
        FontBytes.putU16(&maxp, 4, 65535)
        let glyf = [UInt8](repeating: 0, count: 70000)
        return Sfnt.build([Sfnt.replacing(withLongLoca(tables, glyf, loca), "maxp", maxp)])
    }

    /// The synthetic font with the loca entry that ends glyph 3 (a composite of 28 bytes) moved to `length` bytes.
    static func cutComposite(_ length: Int) throws -> [UInt8] {
        var font = try ttf()
        let loca = ProgramFonts.tableOffset(font, "loca")
        let start = (Int(font[loca + 6]) << 8) | Int(font[loca + 7])
        FontBytes.putU16(&font, loca + 8, start + length / 2)
        return font
    }
}
