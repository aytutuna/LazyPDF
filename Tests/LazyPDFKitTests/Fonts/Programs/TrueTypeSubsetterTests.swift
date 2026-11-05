import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Programs/TrueTypeSubsetterTests.cs: the same cases, except that
// PdfPigReadsTheSubset, whose only assertions are PdfPig's, has no twin. The tests read installed fonts and return
// early when one is missing, as the C# does; the golden files and SyntheticFontTests cover the subsetter on the
// synthetic font, where the runners have no installed one.

final class TrueTypeSubsetterTests: XCTestCase {
    private func glyphsOf(_ f: TrueTypeFont, _ text: String) -> [Int] {
        var seen = Set<Int>()
        var ids: [Int] = []
        for c in text.unicodeScalars {
            let g = f.glyphForCodePoint(Int(c.value))
            if seen.insert(g).inserted { ids.append(g) }
        }
        return ids
    }

    private func assertSameGlyphs(_ source: TrueTypeFont, _ subset: TrueTypeFont, _ map: [Int: Int], file: StaticString = #filePath, line: UInt = #line) throws {
        for (old, new) in map {
            XCTAssertEqual(source.getAdvance(old), subset.getAdvance(new), file: file, line: line)
            XCTAssertEqual(source.getBounds(old), subset.getBounds(new), file: file, line: line)
            let a = try XCTUnwrap(source.getOutline(old), file: file, line: line)
            let b = try XCTUnwrap(subset.getOutline(new), file: file, line: line)
            XCTAssertEqual(a.segments, b.segments, file: file, line: line)
        }
    }

    func test_keptGlyphsKeepOutlineAndAdvance() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let source = try XCTUnwrap(TrueTypeFont.tryParse(data))
        let ids = glyphsOf(source, "Hello, World! Şğıİ çöü ÇÖÜ 0123456789")

        let result = TrueTypeSubsetter.subset(data, ids)

        XCTAssertEqual(result.status, .ok)
        let subset = try XCTUnwrap(TrueTypeFont.tryParse(result.data))
        XCTAssertEqual(result.glyphMap.count, subset.glyphCount)
        XCTAssertEqual(result.glyphMap[0], 0)
        for g in ids { XCTAssertNotNil(result.glyphMap[g]) }
        XCTAssertEqual(source.unitsPerEm, subset.unitsPerEm)
        XCTAssertEqual(source.ascent, subset.ascent)
        XCTAssertEqual(source.descent, subset.descent)
        XCTAssertEqual(source.postScriptName, subset.postScriptName)
        XCTAssertTrue(subset.hasOutlines)
        try assertSameGlyphs(source, subset, result.glyphMap)
        XCTAssertTrue(result.data.count < data.count / 10)
    }

    func test_newIdsFollowTheOrderOfTheOldOnes() {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let map = TrueTypeSubsetter.subset(data, [500, 20, 300, 20]).glyphMap

        XCTAssertEqual(map.count, 4)
        XCTAssertEqual(map[0], 0)
        XCTAssertEqual(map[20], 1)
        XCTAssertEqual(map[300], 2)
        XCTAssertEqual(map[500], 3)
    }

    func test_compositeGlyphsPullInTheirComponents() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let source = try XCTUnwrap(TrueTypeFont.tryParse(data))
        let eacute = source.glyphForCodePoint(0xE9)

        let result = TrueTypeSubsetter.subset(data, [eacute])

        XCTAssertTrue(result.glyphMap.count >= 3, "a composite keeps its parts")
        let subset = try XCTUnwrap(TrueTypeFont.tryParse(result.data))
        try assertSameGlyphs(source, subset, result.glyphMap)
        let mapped = try XCTUnwrap(result.glyphMap[eacute])
        XCTAssertFalse(try XCTUnwrap(subset.getOutline(mapped)).isEmpty)
    }

    func test_unknownGlyphIdsAreIgnored() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }

        let result = TrueTypeSubsetter.subset(data, [-5, 99999, 70000])

        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(Array(result.glyphMap.keys), [0])
        XCTAssertEqual(try XCTUnwrap(TrueTypeFont.tryParse(result.data)).glyphCount, 1)
    }

    func test_checksumsAndDirectoryAreValid() throws {
        guard let data = ProgramFonts.windows("times.ttf") else { return }
        let source = try XCTUnwrap(TrueTypeFont.tryParse(data))
        let result = TrueTypeSubsetter.subset(data, glyphsOf(source, "Merhaba dünya ğşı"))
        let font = result.data

        XCTAssertEqual(sum(font), 0xB1B0AFBA)

        let count = (Int(font[4]) << 8) | Int(font[5])
        var previous = ""
        for i in 0..<count {
            let at = 12 + 16 * i
            let tag = Latin1.string(Array(font[at..<at + 4]))
            XCTAssertTrue(previous < tag, "tags ascend")
            previous = tag
            let stored = readU32(font, at + 4)
            let offset = Int(readU32(font, at + 8))
            let length = Int(readU32(font, at + 12))
            XCTAssertEqual(offset % 4, 0)
            var table = Array(font[offset..<offset + length])
            if tag == "head" { for k in 8..<12 { table[k] = 0 } }
            XCTAssertEqual(stored, sum(table), tag)
        }
        XCTAssertEqual(1 << ((Int(font[8]) << 8) | Int(font[9])), ((Int(font[6]) << 8) | Int(font[7])) / 16)
        for tag in ["head", "hhea", "maxp", "hmtx", "loca", "glyf"] {
            XCTAssertTrue(ProgramFonts.directoryEntry(font, tag) > 0, tag)
        }
    }

    private func readU32(_ d: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(d[o]) << 24) | (UInt32(d[o + 1]) << 16) | (UInt32(d[o + 2]) << 8) | UInt32(d[o + 3])
    }

    private func sum(_ d: [UInt8]) -> UInt32 {
        var total: UInt32 = 0
        var i = 0
        while i < d.count {
            var w: UInt32 = 0
            for k in 0..<4 { w = (w << 8) | (i + k < d.count ? UInt32(d[i + k]) : 0) }
            total = total &+ w
            i += 4
        }
        return total
    }

    func test_wholeFontKeepsLongLocaWorking() throws {
        guard let data = ProgramFonts.windows("segoeui.ttf") else { return }
        let source = try XCTUnwrap(TrueTypeFont.tryParse(data))

        let result = TrueTypeSubsetter.subset(data, Array(0..<source.glyphCount))

        XCTAssertEqual(result.status, .ok)
        let subset = try XCTUnwrap(TrueTypeFont.tryParse(result.data))
        XCTAssertEqual(source.glyphCount, subset.glyphCount)
        var g = 0
        while g < source.glyphCount {
            let mapped = try XCTUnwrap(result.glyphMap[g])
            XCTAssertEqual(try XCTUnwrap(source.getOutline(g)).segments, try XCTUnwrap(subset.getOutline(mapped)).segments)
            XCTAssertEqual(source.getAdvance(g), subset.getAdvance(g))
            g += 17
        }
    }

    func test_fontsThatForbidEmbeddingAreReported() {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let os2 = ProgramFonts.tableOffset(data, "OS/2")

        let cases: [(Int, SubsetStatus)] = [(2, .embeddingForbidden), (0x200, .embeddingForbidden), (0x100, .subsettingForbidden)]
        for (fsType, expected) in cases {
            var copy = data
            copy[os2 + 8] = UInt8(truncatingIfNeeded: fsType >> 8)
            copy[os2 + 9] = UInt8(truncatingIfNeeded: fsType)
            let result = TrueTypeSubsetter.subset(copy, [36, 37])
            XCTAssertEqual(result.status, expected, "\(fsType)")
            XCTAssertTrue(result.data.isEmpty)
            XCTAssertTrue(result.glyphMap.isEmpty)
        }
    }

    func test_cffAndGarbageAreNotSubset() {
        if let otf = ProgramFonts.otf() {
            XCTAssertEqual(TrueTypeSubsetter.subset(otf, [1, 2]).status, .notTrueType)
        }
        XCTAssertEqual(TrueTypeSubsetter.subset([1, 2, 3], [1]).status, .unreadable)
        XCTAssertEqual(TrueTypeSubsetter.subset([UInt8](repeating: 0, count: 500), [1]).status, .unreadable)
    }

    func test_collectionMemberIsSubsetByIndex() throws {
        guard let data = ProgramFonts.windows("msgothic.ttc") else { return }
        let source = try XCTUnwrap(TrueTypeFont.tryParse(data, 0))
        let ids = glyphsOf(source, "あいう漢字ABC")

        let result = TrueTypeSubsetter.subset(data, ids, 0)

        if !source.embeddingAllowed {
            XCTAssertEqual(result.status, .embeddingForbidden)
            return
        }
        XCTAssertEqual(result.status, .ok)
        let subset = try XCTUnwrap(TrueTypeFont.tryParse(result.data))
        try assertSameGlyphs(source, subset, result.glyphMap)
        XCTAssertEqual(TrueTypeSubsetter.subset(data, ids, 99).status, .unreadable)
    }

    func test_glyphsThatAddUpPastTheIntRangeAreRefused() throws {
        let data = try SyntheticFonts.hugeGlyphs()
        XCTAssertEqual(try XCTUnwrap(TrueTypeFont.tryParse(data)).glyphCount, 65535)

        let result = TrueTypeSubsetter.subset(data, 0..<65535)

        XCTAssertEqual(result.status, .unreadable)
        XCTAssertTrue(result.data.isEmpty)
        XCTAssertTrue(result.glyphMap.isEmpty)
        XCTAssertEqual(TrueTypeSubsetter.subset(data, [2, 4]).status, .ok)
    }
}
