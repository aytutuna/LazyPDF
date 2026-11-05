import XCTest
@testable import LazyPDFKit

// No C# twin. The C# tests that need a collection, an OpenType font with CFF outlines or a font with a long loca
// read an installed font, and the Swift runners have none of them. These build the same shapes from the synthetic
// font (SyntheticFonts.swift) and read the cases the damage tests and the golden dumps would miss: the readers at
// positions far outside the bytes, and a subset whose glyphs add up past an Int32.

enum FontDamage {
    /// Reads everything a caller can ask of a font file, so that a trap anywhere in the layer ends the test.
    static func exercise(_ data: [UInt8], every step: Int = 7) {
        guard let f = TrueTypeFont.tryParse(data) else { return }
        _ = f.postScriptName
        _ = f.glyphForCodePoint(0x11F)
        _ = f.glyphForVariation(0x11F, 0xFE00)
        _ = f.glyphForVariation(0x41, 0xFE00)
        _ = f.glyphForName("gbreve")
        let skip = max(step, f.glyphCount / 64)
        var g = 0
        while g < f.glyphCount {
            _ = f.getAdvance(g)
            _ = f.getLeftSideBearing(g)
            _ = f.getBounds(g)
            _ = f.getOutline(g)
            _ = f.glyphName(g)
            g += skip
        }
        let subset = TrueTypeSubsetter.subset(data, [1, 2, 3, 5, 6, 100, 20000])
        if subset.status == .ok { XCTAssertNotNil(TrueTypeFont.tryParse(subset.data)) }
        _ = EmbeddedFontBuilder.build(data, ["A\u{11F}B\u{C0} "])
    }

    static func damage(_ data: [UInt8], cutEvery: Int, rounds: Int, _ rng: inout ProgramFonts.Random) {
        var cut = 0
        while cut < data.count {
            exercise(Array(data[..<cut]), every: 1)
            cut += cutEvery
        }
        for _ in 0..<rounds {
            var copy = data
            let span = min(copy.count, 4000)
            for _ in 0..<(1 + rng.next(40)) { copy[rng.next(span)] = UInt8(rng.next(256)) }
            exercise(copy, every: 1)
        }
        for tag in ["glyf", "loca", "cmap", "hmtx", "post", "head", "maxp", "hhea", "name", "OS/2", "CFF "] {
            let at = ProgramFonts.tableOffset(data, tag)
            if at < 0 { continue }
            for _ in 0..<20 {
                var copy = data
                for _ in 0..<(1 + rng.next(60)) { copy[at + rng.next(min(4000, copy.count - at))] = UInt8(rng.next(256)) }
                exercise(copy, every: 1)
            }
        }
    }
}

final class SyntheticFontTests: XCTestCase {
    func test_collectionOpensEachFontByIndex() throws {
        let data = try SyntheticFonts.collection()

        XCTAssertEqual(TrueTypeFont.collectionCount(data), 2)
        let first = try XCTUnwrap(TrueTypeFont.tryParse(data))
        let second = try XCTUnwrap(TrueTypeFont.tryParse(data, 1))
        XCTAssertEqual(first.postScriptName, "TestSans-Regular")
        XCTAssertEqual(second.postScriptName, "TestSans-Oblique")
        XCTAssertEqual(first.getOutline(3)?.segments, second.getOutline(3)?.segments)
        XCTAssertNotNil(second.getOutline(3))
        for index in [2, -1, Int.max, Int.min] { XCTAssertNil(TrueTypeFont.tryParse(data, index), "\(index)") }
        XCTAssertNil(TrueTypeFont.tryParse(Array(data[..<16]), 1))
    }

    func test_collectionMemberIsSubsetByIndex() throws {
        let data = try SyntheticFonts.collection()

        let second = TrueTypeSubsetter.subset(data, [1, 3], 1)

        XCTAssertEqual(second.status, .ok)
        XCTAssertEqual(second.glyphMap, [0: 0, 1: 1, 3: 2, 4: 3])
        XCTAssertEqual(try XCTUnwrap(TrueTypeFont.tryParse(second.data)).postScriptName, "TestSans-Oblique")
        XCTAssertEqual(try XCTUnwrap(TrueTypeFont.tryParse(TrueTypeSubsetter.subset(data, [1]).data)).postScriptName, "TestSans-Regular")
        for index in [2, Int.max, Int.min] { XCTAssertEqual(TrueTypeSubsetter.subset(data, [1], index).status, .unreadable, "\(index)") }
    }

    func test_collectionIsEmbeddedOnlyAsASubset() throws {
        let (built, status) = EmbeddedFontBuilder.build(try SyntheticFonts.collection(), ["AB"], 1)

        XCTAssertEqual(status, .ok)
        let font = try XCTUnwrap(built)
        XCTAssertTrue(font.isSubset)
        XCTAssertTrue(font.baseFont.hasSuffix("+TestSans-Oblique"))
        XCTAssertEqual(font.codes, [0x41: 1, 0x42: 2])

        let whole = EmbeddedFontBuilder.build(try SyntheticFonts.collection(whole: true), ["AB"], 1)
        XCTAssertNil(whole.font)
        XCTAssertEqual(whole.status, .unreadable)
        XCTAssertEqual(EmbeddedFontBuilder.build(try SyntheticFonts.collection(), ["AB"], Int.max).status, .unreadable)
    }

    func test_openTypeCffExposesTheCffOutlines() throws {
        let cff = CffBuilder.nameKeyed()
        let direct = try XCTUnwrap(CffFont.tryParse(cff))
        let f = try XCTUnwrap(TrueTypeFont.tryParse(try SyntheticFonts.openType(cff)))

        XCTAssertTrue(f.isCff)
        XCTAssertTrue(f.hasOutlines)
        XCTAssertTrue(f.hasTable("CFF "))
        XCTAssertFalse(f.hasTable("glyf"))
        XCTAssertEqual(f.glyphCount, 4)
        XCTAssertEqual([0x41, 0x42, 0xC0].map { f.glyphForCodePoint($0) }, [1, 2, 3])
        for g in 0..<4 {
            XCTAssertEqual(f.getOutline(g)?.segments, direct.getOutline(g)?.segments, "\(g)")
            XCTAssertEqual(f.getBounds(g), direct.getOutline(g)?.bounds(), "\(g)")
        }
        XCTAssertTrue(try XCTUnwrap(f.getOutline(1)).segments.count > 0)
        XCTAssertNil(f.getOutline(4))
        XCTAssertNil(f.getOutline(-1))
        XCTAssertEqual(f.getAdvance(1), 600)
        XCTAssertEqual(f.glyphName(1), "A")
        XCTAssertEqual(f.glyphName(3), "custom")
        XCTAssertEqual(f.glyphForName("B"), 2)
    }

    func test_openTypeCffIsEmbeddedWholeWithItsCids() throws {
        let name = try SyntheticFonts.openType(CffBuilder.nameKeyed())
        let named = EmbeddedFontBuilder.build(name, ["AB"])
        XCTAssertEqual(named.status, .ok)
        let font = try XCTUnwrap(named.font)
        XCTAssertTrue(font.isCff)
        XCTAssertFalse(font.isSubset)
        XCTAssertEqual(font.program, name)
        XCTAssertEqual(font.baseFont, "TestSans-Regular")
        XCTAssertEqual(font.codes, [0x41: 1, 0x42: 2])
        XCTAssertEqual(font.widths, [WidthRun(firstCid: 1, widths: [600, 550])])

        let cid = try SyntheticFonts.openType(CffBuilder.cidKeyed())
        let keyed = try XCTUnwrap(EmbeddedFontBuilder.build(cid, ["AB"]).font)
        XCTAssertEqual(keyed.codes, [0x41: 10, 0x42: 11])
        XCTAssertEqual(keyed.widths, [WidthRun(firstCid: 10, widths: [600, 550])])

        XCTAssertEqual(TrueTypeSubsetter.subset(name, [1, 2]).status, .notTrueType)
        XCTAssertEqual(TrueTypeSubsetter.subset(cid, [1, 2]).status, .notTrueType)
    }

    func test_longLocaIsReadAndWritten() throws {
        let original = try XCTUnwrap(TrueTypeFont.tryParse(try SyntheticFonts.ttf()))
        let data = try SyntheticFonts.longLoca()
        let source = try XCTUnwrap(TrueTypeFont.tryParse(data))

        XCTAssertEqual(source.locaFormat, 1)
        for g in 0..<7 {
            XCTAssertEqual(source.getOutline(g)?.segments, original.getOutline(g)?.segments, "\(g)")
            XCTAssertEqual(source.getBounds(g), original.getBounds(g), "\(g)")
            XCTAssertEqual(source.getAdvance(g), original.getAdvance(g), "\(g)")
        }

        // Glyph 1 and its padding make the glyf table 0x20000 bytes or more, which needs the long form.
        let long = TrueTypeSubsetter.subset(data, [1])
        XCTAssertEqual(long.status, .ok)
        XCTAssertEqual(long.glyphMap, [0: 0, 1: 1])
        try checkSubset(long.data, source, 1, 1, locaFormat: 1, locaBytes: 12)
        XCTAssertTrue(tableLength(long.data, "glyf") >= 0x20000)

        let short = TrueTypeSubsetter.subset(data, [2])
        XCTAssertEqual(short.status, .ok)
        try checkSubset(short.data, source, 2, 1, locaFormat: 0, locaBytes: 6)
        XCTAssertTrue(tableLength(short.data, "glyf") < 0x20000)
    }

    private func tableLength(_ font: [UInt8], _ tag: String) -> Int {
        Int(FontSpan(font).u32(ProgramFonts.directoryEntry(font, tag) + 12))
    }

    private func checkSubset(_ font: [UInt8], _ source: TrueTypeFont, _ old: Int, _ new: Int, locaFormat: Int, locaBytes: Int) throws {
        XCTAssertEqual(FontSpan(font).u16(ProgramFonts.tableOffset(font, "head") + 50), locaFormat)
        XCTAssertEqual(tableLength(font, "loca"), locaBytes)
        let subset = try XCTUnwrap(TrueTypeFont.tryParse(font))
        XCTAssertEqual(subset.locaFormat, locaFormat)
        XCTAssertEqual(subset.getOutline(new)?.segments, source.getOutline(old)?.segments)
        XCTAssertEqual(subset.getBounds(new), source.getBounds(old))
        XCTAssertEqual(subset.getAdvance(new), source.getAdvance(old))
    }

    func test_truncatedCompositeNeverTraps() throws {
        for length in stride(from: 10, through: 28, by: 2) {
            let data = try SyntheticFonts.cutComposite(length)
            let result = TrueTypeSubsetter.subset(data, [3])
            XCTAssertEqual(result.status, .ok, "\(length)")
            XCTAssertNotNil(TrueTypeFont.tryParse(result.data), "\(length)")
            let f = try XCTUnwrap(TrueTypeFont.tryParse(data))
            _ = f.getOutline(3)
            XCTAssertEqual(EmbeddedFontBuilder.build(data, ["\u{C0}"]).status, .ok, "\(length)")
        }
    }

    func test_damagedSyntheticFontsNeverThrow() throws {
        var rng = ProgramFonts.Random(11)
        let plain = try SyntheticFonts.ttf()
        FontDamage.damage(plain, cutEvery: 1, rounds: 300, &rng)
        FontDamage.damage(try SyntheticFonts.longLoca(), cutEvery: 4001, rounds: 100, &rng)
        FontDamage.damage(try SyntheticFonts.collection(), cutEvery: 13, rounds: 150, &rng)
        FontDamage.damage(try SyntheticFonts.openType(CffBuilder.nameKeyed()), cutEvery: 3, rounds: 150, &rng)
        FontDamage.damage(try SyntheticFonts.openType(CffBuilder.cidKeyed()), cutEvery: 3, rounds: 150, &rng)
    }

    func test_readersFarOutsideTheBytesReadZero() throws {
        let far = [Int.max, Int.min, -1, 1 << 40, 8]
        let span = FontSpan([1, 2, 3, 4, 5, 6, 7, 8])
        for o in far {
            XCTAssertEqual(span.u8(o), 0, "\(o)")
            XCTAssertEqual(span.u16(o), 0, "\(o)")
            XCTAssertEqual(span.i16(o), 0, "\(o)")
            XCTAssertEqual(span.u24(o), 0, "\(o)")
            XCTAssertEqual(span.u32(o), 0, "\(o)")
            XCTAssertEqual(span.offset32(o), 0, "\(o)")
            XCTAssertEqual(span.tag(o), "", "\(o)")
            XCTAssertEqual(span.slice(o, Int.max).length, o == Int.min || o == -1 ? 8 : 0, "\(o)")
            XCTAssertEqual(span.slice(o, Int.min).length, 0, "\(o)")
            XCTAssertEqual(span.slice(from: o).length, o == Int.min || o == -1 ? 8 : 0, "\(o)")
        }

        let data = try SyntheticFonts.ttf()
        let f = try XCTUnwrap(TrueTypeFont.tryParse(data))
        for index in [Int.max, Int.min, -1] {
            XCTAssertNil(TrueTypeFont.tryParse(data, index), "\(index)")
            XCTAssertEqual(TrueTypeSubsetter.subset(data, [1], index).status, .unreadable, "\(index)")
        }
        for g in far where g != 8 {
            XCTAssertEqual(f.glyphForCodePoint(g), 0, "\(g)")
            XCTAssertEqual(f.glyphForCmap(3, 1, g), 0, "\(g)")
            XCTAssertEqual(f.glyphForCmap(1, 0, g), 0, "\(g)")
            XCTAssertEqual(f.glyphForCmap(3, 10, g), 0, "\(g)")
            XCTAssertEqual(f.glyphForCmap(g, g, g), 0, "\(g)")
            XCTAssertFalse(f.hasCmap(g, g), "\(g)")
            for selector in far { XCTAssertEqual(f.glyphForVariation(g, selector), 0, "\(g) \(selector)") }
            XCTAssertEqual(f.getAdvance(g), 0, "\(g)")
            XCTAssertEqual(f.getLeftSideBearing(g), 0, "\(g)")
            XCTAssertNil(f.getBounds(g), "\(g)")
            XCTAssertNil(f.getOutline(g), "\(g)")
            XCTAssertNil(f.glyphName(g), "\(g)")
        }
        let kept = TrueTypeSubsetter.subset(data, far + [1])
        XCTAssertEqual(kept.status, .ok)
        XCTAssertEqual(kept.glyphMap, [0: 0, 1: 1])

        let cff = CffBuilder.nameKeyed()
        let font = try XCTUnwrap(CffFont.tryParse(cff))
        for g in far where g != 8 {
            XCTAssertEqual(font.getWidth(g), 0, "\(g)")
            XCTAssertNil(font.getOutline(g), "\(g)")
            XCTAssertNil(font.glyphName(g), "\(g)")
            XCTAssertEqual(font.glyphForCode(g), 0, "\(g)")
            XCTAssertEqual(font.glyphForCid(g), 0, "\(g)")
            _ = font.cidForGlyph(g)
        }
        for offset in far + [0, 1] {
            for length in far + [0, 3, 4, cff.count] {
                let valid = offset == 0 && length == cff.count
                XCTAssertEqual(CffFont.tryParse(cff, offset, length) != nil, valid, "\(offset) \(length)")
            }
        }
    }

    func test_parseDoubleReadsWhatDoubleTryParseReads() throws {
        for text in ["NaN", "nan", "+NaN", "-NaN", "+nan", " -nan "] {
            XCTAssertEqual(FontBytes.parseDouble(text)?.isNaN, true, text)
        }
        XCTAssertEqual(FontBytes.parseDouble("Infinity"), Double.infinity)
        XCTAssertEqual(FontBytes.parseDouble("+INFINITY"), Double.infinity)
        XCTAssertEqual(FontBytes.parseDouble("-infinity"), -Double.infinity)
        for text in ["inf", "-inf", "+inf", "nan(1)", "0x10", "\u{221E}", "", " "] { XCTAssertNil(FontBytes.parseDouble(text), text) }

        let header = Latin1.bytes("[0.001 0 0 0.001 0 0]")
        let signed = Sfnt.replacing(Type1Builder.build(.binary), header, Latin1.bytes("[+NaN 0 0 0.001 0 0]"))
        let f = try XCTUnwrap(Type1Font.tryParse(signed))
        XCTAssertEqual(f.fontMatrix.count, 6)
        XCTAssertTrue(f.fontMatrix[0].isNaN)
        XCTAssertEqual(f.fontMatrix[3], 0.001)
    }
}
