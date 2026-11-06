import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Ocr/GlyphlessFontTests.cs: the same cases. A Swift string holds no lone surrogate, so
// the lone U+D800 of CodesAreUtf16UnitsAndWideCharactersGetSurrogateCodes is the replacement character U+FFFD here (its
// code is the same) and the assertion that Covers refuses it has no twin.

final class GlyphlessFontTests: XCTestCase {
    private func wide(_ codePoint: Int) -> String {
        Unicode.Scalar(UInt32(codePoint)).map { String($0) } ?? ""
    }

    func test_programIsATrueTypeFontWithOneEmptyHalfEmGlyph() throws {
        let font = try XCTUnwrap(TrueTypeFont.tryParse(GlyphlessFont.program))
        XCTAssertEqual(font.glyphCount, 2)
        XCTAssertEqual(font.unitsPerEm, 1000)
        XCTAssertEqual(font.getAdvance(1), 500)
        XCTAssertNil(font.getBounds(1))
        XCTAssertEqual(GlyphlessFont.program, GlyphlessFont.build())
    }

    func test_cidToGidMapSendsEveryCodeToGlyphOne() throws {
        let map = try PdfFilters.inflate(GlyphlessFont.cidToGidMap)
        XCTAssertEqual(map.count, GlyphlessFont.codeCount * 2)
        for i in stride(from: 0, to: map.count, by: 2) where map[i] != 0 || map[i + 1] != 1 {
            XCTFail("code \(i / 2) maps to \(map[i]) \(map[i + 1])")
            break
        }
    }

    func test_codesAreUtf16UnitsAndWideCharactersGetSurrogateCodes() {
        let emoji = wide(0x1F600), cjk = wide(0x20000), lone = "\u{FFFD}"
        let codes = GlyphlessCodes.for(["a" + emoji, cjk + emoji + lone])
        XCTAssertEqual(codes.codes("a" + emoji), [0x61, 0xD800])
        XCTAssertEqual(codes.codes(cjk + emoji + lone), [0xD801, 0xD800, GlyphlessCodes.replacementCode])
        XCTAssertEqual(codes.bytes("a" + emoji), [0x00, 0x61, 0xD8, 0x00])
        XCTAssertTrue(codes.covers("a" + cjk))
        XCTAssertFalse(codes.covers(wide(0x1F601)))
    }

    func test_moreWideCharactersThanCodesBecomeReplacements() {
        let texts = (0..<(GlyphlessCodes.supplementaryCapacity + 10)).map { wide(0x20000 + $0) }
        let codes = GlyphlessCodes.for(texts)
        XCTAssertEqual(codes.supplementary.count, GlyphlessCodes.supplementaryCapacity)
        XCTAssertEqual(codes.codes(texts[texts.count - 1]), [GlyphlessCodes.replacementCode])
    }

    func test_toUnicodeMapGivesTextBackAndTheFontReadsBackItsCodes() throws {
        let emoji = wide(0x1F600)
        let codes = GlyphlessCodes.for([emoji, wide(0x20000)])
        let map = CMap.parse(Array(codes.toUnicodeCMap().utf8))
        XCTAssertEqual(map.unicodeOf(0x41), "A")
        XCTAssertEqual(map.unicodeOf(0x11F), "\u{11F}")
        XCTAssertEqual(map.unicodeOf(0xD800), emoji)
        XCTAssertEqual(map.unicodeOf(0xD801), wide(0x20000))
        XCTAssertNil(map.unicodeOf(0xD802))

        let document = try OcrKit.scan()
        _ = try PdfOcrLayer.add(document, [OcrPageWords(0, [OcrKit.word(emoji + "x" + wide(0x20000), 10, 10, 90, 20)], 400, 600)], "en")
        let font = try XCTUnwrap(OcrLayerContent.fontOf(document, document.pages[0], OcrLayerContent.fontName))
        let read = GlyphlessCodes.from(font)
        XCTAssertEqual(read.supplementary, [0x1F600, 0x20000])
        XCTAssertEqual(codes.codes(emoji + "x"), read.codes(emoji + "x"))
    }
}
