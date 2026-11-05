import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Programs/EmbeddedFontBuilderTests.cs: the same cases. Build returns the
// font and the status in a tuple where the C# has an out parameter. Assert.Same on the program bytes is a
// comparison of the bytes here: a Swift array has no identity. The tests read installed fonts and return early
// when one is missing, as the C# does.

final class EmbeddedFontBuilderTests: XCTestCase {
    private let turkish = "Şğıİ Çalışma ÖĞRETMEN dünya ÜÇ çöğüşıİ"

    private func setFsType(_ font: [UInt8], _ fsType: Int) -> [UInt8] {
        var copy = font
        let os2 = ProgramFonts.tableOffset(copy, "OS/2")
        copy[os2 + 8] = UInt8(truncatingIfNeeded: fsType >> 8)
        copy[os2 + 9] = UInt8(truncatingIfNeeded: fsType)
        return copy
    }

    func test_turkishTextGetsACodeForEveryLetter() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let source = try XCTUnwrap(TrueTypeFont.tryParse(data))

        let (built, status) = EmbeddedFontBuilder.build(data, [turkish])
        let font = try XCTUnwrap(built)

        XCTAssertEqual(status, .ok)
        XCTAssertFalse(font.isCff)
        XCTAssertTrue(font.isSubset)
        XCTAssertNotNil(font.baseFont.range(of: "^[A-Z]{6}\\+Arial", options: .regularExpression), font.baseFont)
        XCTAssertTrue(font.missing.isEmpty)
        for scalar in turkish.unicodeScalars where scalar.value != 0x20 {
            XCTAssertNotNil(font.codes[Int(scalar.value)], String(scalar))
        }
        for cp in [0x011F, 0x011E, 0x015F, 0x015E, 0x0131, 0x0130] {
            XCTAssertNotEqual(font.codes[cp], 0, "\(cp)")
        }

        let subset = try XCTUnwrap(TrueTypeFont.tryParse(font.program))
        for (cp, code) in font.codes {
            let original = source.glyphForCodePoint(cp)
            XCTAssertEqual(try XCTUnwrap(source.getOutline(original)).segments, try XCTUnwrap(subset.getOutline(code)).segments, "\(cp)")
            XCTAssertEqual(source.getAdvance(original), subset.getAdvance(code), "\(cp)")
        }
    }

    func test_encodeWritesTwoByteCodesThatToUnicodeReverses() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let font = try XCTUnwrap(EmbeddedFontBuilder.build(data, [turkish, "extra"]).font)

        let bytes = font.encode(turkish)
        let back = font.toUnicode()

        XCTAssertEqual(turkish.utf16.count * 2, bytes.count)
        var text = ""
        for i in 0..<bytes.count / 2 {
            let cp = try XCTUnwrap(back[(Int(bytes[2 * i]) << 8) | Int(bytes[2 * i + 1])])
            text.unicodeScalars.append(try XCTUnwrap(Unicode.Scalar(UInt32(cp))))
        }
        XCTAssertEqual(text, turkish)
    }

    func test_widthsAreInThousandthsAndGroupedInRuns() throws {
        guard let data = ProgramFonts.windows("times.ttf") else { return }
        let source = try XCTUnwrap(TrueTypeFont.tryParse(data))
        let font = try XCTUnwrap(EmbeddedFontBuilder.build(data, ["abcdefgh ğ"]).font)

        var all: [Int: Int] = [:]
        for run in font.widths {
            for i in 0..<run.widths.count {
                XCTAssertNil(all[run.firstCid + i])
                all[run.firstCid + i] = run.widths[i]
            }
        }

        XCTAssertEqual(font.codes.count, all.count)
        for (cp, code) in font.codes {
            let units = Double(source.getAdvance(source.glyphForCodePoint(cp)))
            XCTAssertEqual(Int((units * 1000.0 / Double(source.unitsPerEm)).rounded(.toNearestOrEven)), all[code], "\(cp)")
        }
        XCTAssertTrue(font.widths.count < font.codes.count, "consecutive codes share an entry")
        for i in 1..<max(1, font.widths.count) {
            XCTAssertTrue(font.widths[i].firstCid > font.widths[i - 1].firstCid + font.widths[i - 1].widths.count)
        }
        XCTAssertEqual(font.defaultWidth, 1000)
    }

    func test_charactersTheFontLacksAreReportedAndEncodeAsNotdef() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }

        let (built, status) = EmbeddedFontBuilder.build(data, ["a中\u{1F600}b"])
        let font = try XCTUnwrap(built)

        XCTAssertEqual(status, .ok)
        XCTAssertEqual(font.missing, [0x4E2D, 0x1F600])
        XCTAssertNil(font.codes[0x4E2D])
        let bytes = font.encode("a中b")
        XCTAssertEqual(Array(bytes[2..<4]), [0, 0])
        XCTAssertNotEqual(Array(bytes[0..<2]), [0, 0])
    }

    func test_controlCharactersAndEmptyTextAreHarmless() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }

        let font = try XCTUnwrap(EmbeddedFontBuilder.build(data, ["a\r\n\tb", ""]).font)
        XCTAssertEqual(font.codes.count, 2)
        XCTAssertTrue(font.missing.isEmpty)

        let (built, status) = EmbeddedFontBuilder.build(data, [])
        let none = try XCTUnwrap(built)
        XCTAssertEqual(status, .ok)
        XCTAssertTrue(none.codes.isEmpty)
        XCTAssertTrue(none.widths.isEmpty)
        XCTAssertEqual(try XCTUnwrap(TrueTypeFont.tryParse(none.program)).glyphCount, 1)
    }

    func test_descriptorValuesAreScaledToThousandths() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }

        let d = try XCTUnwrap(EmbeddedFontBuilder.build(data, ["A"]).font).descriptor

        XCTAssertEqual(d.flags & 32, 32)
        XCTAssertEqual(d.flags & 64, 0)
        XCTAssertEqual(d.italicAngle, 0)
        XCTAssertEqual(d.ascent, 905)
        XCTAssertTrue(d.descent < 0)
        XCTAssertTrue((600...800).contains(d.capHeight))
        XCTAssertTrue((40...200).contains(d.stemV))
        XCTAssertEqual(d.fontBBox.count, 4)
        XCTAssertTrue(d.fontBBox[2] > d.fontBBox[0] && d.fontBBox[3] > d.fontBBox[1])
    }

    func test_italicFontSetsTheItalicFlag() throws {
        guard let data = ProgramFonts.windows("ariali.ttf") else { return }

        let d = try XCTUnwrap(EmbeddedFontBuilder.build(data, ["A"]).font).descriptor

        XCTAssertEqual(d.flags & 64, 64)
        XCTAssertTrue(d.italicAngle < 0)
    }

    func test_restrictedFontsAreRefused() {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }

        var result = EmbeddedFontBuilder.build(setFsType(data, 2), ["a"])
        XCTAssertNil(result.font)
        XCTAssertEqual(result.status, .embeddingForbidden)
        result = EmbeddedFontBuilder.build(setFsType(data, 0x200), ["a"])
        XCTAssertNil(result.font)
        XCTAssertEqual(result.status, .embeddingForbidden)
    }

    func test_fontThatForbidsSubsettingIsEmbeddedWholeWithGlyphIdsAsCodes() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }
        let patched = setFsType(data, 0x100)
        let source = try XCTUnwrap(TrueTypeFont.tryParse(patched))

        let (built, status) = EmbeddedFontBuilder.build(patched, ["Şğ"])
        let font = try XCTUnwrap(built)

        XCTAssertEqual(status, .ok)
        XCTAssertFalse(font.isSubset)
        XCTAssertEqual(font.program, patched)
        XCTAssertEqual(font.baseFont.replacingOccurrences(of: "MT", with: ""), "Arial")
        XCTAssertEqual(font.codes[0x011F], source.glyphForCodePoint(0x011F))
    }

    func test_openTypeCffIsEmbeddedWholeAsCffFont() throws {
        guard let data = ProgramFonts.otf() else { return }
        let source = try XCTUnwrap(TrueTypeFont.tryParse(data))

        let (built, status) = EmbeddedFontBuilder.build(data, ["Şğıİ"])
        let font = try XCTUnwrap(built)

        XCTAssertEqual(status, .ok)
        XCTAssertTrue(font.isCff)
        XCTAssertFalse(font.isSubset)
        XCTAssertEqual(font.program, data)
        XCTAssertEqual(font.codes[0x015E], source.glyphForCodePoint(0x015E))
        XCTAssertFalse(font.baseFont.contains("+"))
        XCTAssertEqual(font.codes.count, 4)
    }

    func test_collectionMembersAreSubsetButNeverEmbeddedWhole() throws {
        guard let data = ProgramFonts.windows("msgothic.ttc") else { return }
        let source = try XCTUnwrap(TrueTypeFont.tryParse(data, 0))

        var (font, status) = EmbeddedFontBuilder.build(data, ["あいう"], 0)

        if !source.embeddingAllowed {
            XCTAssertNil(font)
            XCTAssertEqual(status, .embeddingForbidden)
            return
        }
        let built = try XCTUnwrap(font)
        XCTAssertTrue(built.isSubset)
        XCTAssertEqual(built.codes.count, 3)
        (font, status) = EmbeddedFontBuilder.build(data, ["あ"], 99)
        XCTAssertNil(font)
        XCTAssertEqual(status, .unreadable)
    }

    func test_sameInputGivesSameBytesAndTextChangesTheTag() throws {
        guard let data = ProgramFonts.windows("arial.ttf") else { return }

        let a = try XCTUnwrap(EmbeddedFontBuilder.build(data, ["abc"]).font)
        let b = try XCTUnwrap(EmbeddedFontBuilder.build(data, ["abc"]).font)
        let c = try XCTUnwrap(EmbeddedFontBuilder.build(data, ["abd"]).font)

        XCTAssertEqual(a.program, b.program)
        XCTAssertEqual(a.baseFont, b.baseFont)
        XCTAssertNotEqual(a.baseFont, c.baseFont)
    }

    func test_garbageIsUnreadable() {
        var result = EmbeddedFontBuilder.build([], ["a"])
        XCTAssertNil(result.font)
        XCTAssertEqual(result.status, .unreadable)
        result = EmbeddedFontBuilder.build([UInt8](repeating: 0, count: 200), ["a"])
        XCTAssertNil(result.font)
        XCTAssertEqual(result.status, .unreadable)
    }
}
