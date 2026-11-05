import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Programs/TrueTypeFontTests.cs: the same cases. Like the C#, the tests
// that read an installed font return early when it is missing; on the CI runners only the Linux DejaVu one can
// be there, so SyntheticFontTests runs the collection, CFF, damage and far-position cases on the synthetic font.
// The damage tests use their own generator where the C# has System.Random.

final class TrueTypeFontTests: XCTestCase {
    func test_arialMetrics() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let f = try XCTUnwrap(TrueTypeFont.tryParse(data))

        XCTAssertEqual(f.unitsPerEm, 2048)
        XCTAssertTrue(f.ascent > 1500 && f.ascent < 2200)
        XCTAssertTrue(f.descent < 0 && f.descent > -800)
        XCTAssertTrue(f.capHeight > 1000 && f.capHeight < 1700)
        XCTAssertEqual(f.getAdvance(f.glyphForCodePoint(0x41)), 1366)
        XCTAssertEqual(f.getAdvance(f.glyphForCodePoint(0x20)), 569)
        XCTAssertEqual(f.familyName, "Arial")
        XCTAssertEqual(f.postScriptName, "ArialMT")
        XCTAssertTrue(f.embeddingAllowed)
        XCTAssertFalse(f.isCff)
    }

    func test_turkishLettersHaveGlyphs() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let f = try XCTUnwrap(TrueTypeFont.tryParse(data))

        for codePoint in [0x011F, 0x015F, 0x0131, 0x0130, 0x011E, 0x015E] {
            let gid = f.glyphForCodePoint(codePoint)
            XCTAssertNotEqual(gid, 0, "\(codePoint)")
            XCTAssertNotNil(f.getOutline(gid), "\(codePoint)")
            XCTAssertTrue(f.getAdvance(gid) > 0, "\(codePoint)")
            XCTAssertNil(f.glyphName(gid), "\(codePoint)")
        }
    }

    func test_glyphNamesComeFromPost() throws {
        guard let data = ProgramFonts.named() else { return }
        let f = try XCTUnwrap(TrueTypeFont.tryParse(data))

        for (codePoint, name) in [(0x011F, "gbreve"), (0x015F, "scedilla"), (0x0131, "dotlessi"), (0x41, "A"), (0x20, "space")] {
            let gid = f.glyphForCodePoint(codePoint)
            XCTAssertNotEqual(gid, 0, name)
            XCTAssertEqual(f.glyphName(gid), name)
            XCTAssertEqual(f.glyphForName(name), gid, name)
            XCTAssertEqual(f.glyphForName("no-such-glyph"), 0, name)
            XCTAssertNil(f.glyphName(-1), name)
            XCTAssertNil(f.glyphName(f.glyphCount), name)
        }
    }

    func test_codePointsOutsideTheFontMapToNotdef() throws {
        guard let data = ProgramFonts.windows("times.ttf") else { return }
        let f = try XCTUnwrap(TrueTypeFont.tryParse(data))

        XCTAssertEqual(f.glyphForCodePoint(0x4E2D), 0)
        XCTAssertEqual(f.glyphForCodePoint(-1), 0)
        XCTAssertEqual(f.glyphForCodePoint(0x10FFFF), 0)
    }

    func test_outlineBoundsMatchTheGlyphHeader() throws {
        guard let data = ProgramFonts.windows("segoeui.ttf") else { return }
        let f = try XCTUnwrap(TrueTypeFont.tryParse(data))

        for ch in "AgSs&@éÖğŞ".unicodeScalars {
            let gid = f.glyphForCodePoint(Int(ch.value))
            let header = try XCTUnwrap(f.getBounds(gid))
            let outline = try XCTUnwrap(f.getOutline(gid))
            let box = try XCTUnwrap(outline.bounds())
            XCTAssertEqual(header, box)
            XCTAssertTrue(outline.segments.contains { $0.op == .quad })
        }
    }

    func test_blankGlyphHasEmptyOutlineAndNoBounds() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let f = try XCTUnwrap(TrueTypeFont.tryParse(data))

        let space = f.glyphForCodePoint(0x20)
        XCTAssertTrue(try XCTUnwrap(f.getOutline(space)).isEmpty)
        XCTAssertNil(f.getBounds(space))
        XCTAssertNil(f.getOutline(f.glyphCount))
        XCTAssertNil(f.getOutline(-1))
        XCTAssertEqual(f.getAdvance(f.glyphCount + 5), 0)
    }

    func test_accentedGlyphIsComposedFromItsParts() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let f = try XCTUnwrap(TrueTypeFont.tryParse(data))

        let e = try XCTUnwrap(f.getOutline(f.glyphForCodePoint(0x65)))
        let eacute = try XCTUnwrap(f.getOutline(f.glyphForCodePoint(0xE9)))
        XCTAssertTrue(eacute.segments.count > e.segments.count)
        let eBox = try XCTUnwrap(e.bounds())
        let eacuteBox = try XCTUnwrap(eacute.bounds())
        XCTAssertEqual(eBox.xMin, eacuteBox.xMin)
        XCTAssertTrue(eacuteBox.yMax > eBox.yMax)
    }

    func test_collectionOpensEachFontByIndex() throws {
        guard let data = ProgramFonts.windows("msgothic.ttc") else { return }

        let count = TrueTypeFont.collectionCount(data)
        XCTAssertTrue(count >= 2)
        let first = try XCTUnwrap(TrueTypeFont.tryParse(data, 0))
        let second = try XCTUnwrap(TrueTypeFont.tryParse(data, 1))
        XCTAssertNotEqual(first.postScriptName, second.postScriptName)
        XCTAssertNotEqual(first.glyphForCodePoint(0x3042), 0)
        XCTAssertNotNil(first.getOutline(first.glyphForCodePoint(0x3042)))
        XCTAssertNil(TrueTypeFont.tryParse(data, count))
        XCTAssertNil(TrueTypeFont.tryParse(data, -1))
    }

    func test_openTypeCffExposesTheCffOutlines() throws {
        guard let data = ProgramFonts.otf() else { return }
        let f = try XCTUnwrap(TrueTypeFont.tryParse(data))

        XCTAssertTrue(f.isCff)
        let gid = f.glyphForCodePoint(0x67)
        XCTAssertNotEqual(gid, 0)
        XCTAssertTrue(try XCTUnwrap(f.getOutline(gid)).segments.contains { $0.op == .cubic })
        XCTAssertTrue(f.getAdvance(gid) > 0)
    }

    func test_notAFontGivesNull() {
        XCTAssertNil(TrueTypeFont.tryParse([]))
        XCTAssertNil(TrueTypeFont.tryParse([UInt8](repeating: 0, count: 100)))
        XCTAssertNil(TrueTypeFont.tryParse(Array("%PDF-1.7 not a font at all".utf8)))
        XCTAssertEqual(TrueTypeFont.collectionCount([1, 2, 3]), 0)
    }

    func test_truncatedAndDamagedFontsNeverThrow() {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        var rng = ProgramFonts.Random(7)

        var cut = 0
        while cut < data.count {
            FontDamage.exercise(Array(data[..<cut]))
            cut += data.count / 97 + 1
        }

        for _ in 0..<60 {
            var copy = data
            for _ in 0..<40 { copy[rng.next(copy.count < 40000 ? copy.count : 40000)] = UInt8(rng.next(256)) }
            FontDamage.exercise(copy)
        }

        // Damage inside glyf, loca and cmap specifically.
        for tag in ["glyf", "loca", "cmap", "hmtx", "post", "head"] {
            let at = ProgramFonts.tableOffset(data, tag)
            for _ in 0..<20 {
                var copy = data
                for _ in 0..<60 { copy[at + rng.next(min(4000, copy.count - at))] = UInt8(rng.next(256)) }
                FontDamage.exercise(copy)
            }
        }
    }

    func test_fsTypeBitsDecideEmbedding() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let os2 = ProgramFonts.tableOffset(data, "OS/2")

        for (fsType, embed, subset) in [(0, true, true), (4, true, true), (8, true, true), (2, false, true), (0x200, false, true), (0x100, true, false), (0x108, true, false)] {
            var copy = data
            copy[os2 + 8] = UInt8(truncatingIfNeeded: fsType >> 8)
            copy[os2 + 9] = UInt8(truncatingIfNeeded: fsType)
            let f = try XCTUnwrap(TrueTypeFont.tryParse(copy))
            XCTAssertEqual(f.embeddingAllowed, embed, "\(fsType)")
            XCTAssertEqual(f.subsettingAllowed, subset, "\(fsType)")
        }
    }
}
