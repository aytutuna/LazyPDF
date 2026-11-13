#if canImport(CoreText)
import Foundation
import LazyPDFApp
import LazyPDFKit
import XCTest

// Mirrors windows/LazyPDF.App.Tests/WpfShaperTests.cs, against Geeza Pro and Arial, which every Mac and iPhone has.

final class CoreTextShaperTests: XCTestCase {
    private let source = CoreTextFontSource()

    private let meem = "\u{0645}", reh = "\u{0631}", hah = "\u{062D}", beh = "\u{0628}", alef = "\u{0627}", lam = "\u{0644}"

    private func file(_ family: String) throws -> FontFile {
        try XCTUnwrap(source.find(family, .regular), "\(family) is not installed")
    }

    private func shape(_ file: FontFile, _ text: String) throws -> [ShapedGlyph] {
        try XCTUnwrap(source.shape(text, file, rightToLeft: true, language: nil))
    }

    func test_sharedShaperGivesTheSameGlyphsOnManyThreads() throws {
        let geeza = try file("Geeza Pro")
        let arial = try file("Arial")
        let text = meem + reh + hah + beh + alef
        let expected = [try shape(geeza, text).map(\.glyph), try shape(arial, text).map(\.glyph)]
        let lock = NSLock()
        var wrong = 0
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let which = i % 2
            let glyphs = source.shape(text, which == 0 ? geeza : arial, rightToLeft: true, language: nil)?.map(\.glyph)
            if glyphs != expected[which] { lock.lock(); wrong += 1; lock.unlock() }
        }
        XCTAssertEqual(wrong, 0)
    }

    func test_arabicLettersTakeTheirJoinedForms() throws {
        let geeza = try file("Geeza Pro")
        let glyphs = try shape(geeza, meem + reh + hah + beh + alef)

        XCTAssertEqual(glyphs.count, 5)
        // The last letter is drawn first on the left; the first letter is drawn on the right.
        XCTAssertEqual(glyphs.map(\.cluster), [4, 3, 2, 1, 0])
        // The meem opens the word and the alef closes it, so neither is the isolated glyph.
        XCTAssertNotEqual(glyphs[4].glyph, try shape(geeza, meem)[0].glyph)
        XCTAssertNotEqual(glyphs[0].glyph, try shape(geeza, alef)[0].glyph)
        XCTAssertTrue(glyphs.allSatisfy { $0.glyph > 0 && $0.advance > 0 })
    }

    func test_lamAlefIsOneGlyphForTwoLetters() throws {
        let geeza = try file("Geeza Pro")
        let glyphs = try shape(geeza, lam + alef + beh)

        XCTAssertEqual(glyphs.count, 2)
        XCTAssertEqual(glyphs.map(\.cluster), [2, 0])
        XCTAssertTrue(glyphs.allSatisfy { $0.glyph > 0 })
    }

    func test_noDeletedGlyphIdsComeThrough() throws {
        let geeza = try file("Geeza Pro")
        let glyphs = try shape(geeza, lam + alef + beh + lam + alef + "\u{064E}")

        XCTAssertFalse(glyphs.isEmpty)
        XCTAssertTrue(glyphs.allSatisfy { $0.glyph > 0 && $0.glyph != 0xFFFF })
    }

    func test_aMarkFollowsItsBaseInReadingOrderAndIsPlacedAbove() throws {
        let geeza = try file("Geeza Pro")
        let glyphs = try shape(geeza, beh + "\u{064E}" + beh)

        XCTAssertEqual(glyphs.map(\.cluster), [2, 0, 0])
        XCTAssertEqual(glyphs[1].advance, 0, accuracy: 0.5)
        XCTAssertNotEqual(glyphs[1].yOffset, 0)
    }

    func test_hebrewComesOutInDrawingOrder() throws {
        let arial = try file("Arial")
        let glyphs = try shape(arial, "\u{05D0}\u{05D1}\u{05D2}")

        XCTAssertEqual(glyphs.map(\.cluster), [2, 1, 0])
        XCTAssertEqual(Set(glyphs.map(\.glyph)).count, 3)
        XCTAssertTrue(glyphs.allSatisfy { $0.glyph > 0 })
    }

    func test_aHebrewPointStaysWithItsLetter() throws {
        let arial = try file("Arial")
        let glyphs = try shape(arial, "\u{05D0}\u{05B8}\u{05D1}")

        // Arial draws the letter and its point as one glyph, so that cluster covers both and the point's place in the
        // text is the gap up to the next cluster.
        XCTAssertEqual(glyphs.map(\.cluster), [2, 0])
        XCTAssertTrue(glyphs.allSatisfy { $0.glyph > 0 && $0.advance > 0 })
    }

    func test_bracketsAreNotMirroredASecondTime() throws {
        let arial = try file("Arial")
        let glyphs = try shape(arial, ")\u{05D0}(")
        let font = try XCTUnwrap(TrueTypeFont.tryParse(arial.data, arial.collectionIndex))
        let open = font.glyphForCodePoint(0x28)
        let close = font.glyphForCodePoint(0x29)

        // Core hands over the run with its brackets already swapped, and they are drawn as they are given.
        XCTAssertEqual(glyphs[0].glyph, open)
        XCTAssertEqual(glyphs[2].glyph, close)
    }

    func test_directionMarksAreDroppedAndClustersKeepTheirPlace() throws {
        let geeza = try file("Geeza Pro")
        let glyphs = try shape(geeza, "\u{200F}" + beh + alef)

        XCTAssertEqual(glyphs.map(\.cluster), [2, 1])
    }

    func test_lettersInALeftToRightRunAndLatinTextAreLeftToTheEngine() throws {
        let geeza = try file("Geeza Pro")

        XCTAssertNil(source.shape(beh + alef, geeza, rightToLeft: false, language: nil))
        XCTAssertNil(source.shape("Hello 123", geeza, rightToLeft: true, language: nil))
    }

    func test_aCharacterTheFontLacksIsLeftToTheEngine() throws {
        let arial = try file("Arial")

        XCTAssertNil(source.shape(beh + "\u{0E01}", arial, rightToLeft: true, language: nil))
    }

    func test_anEmbeddedFontDrawsTheJoinedGlyphs() throws {
        let document = try PdfDocument.open(ApplePdfs.text())
        let font = try XCTUnwrap(try PdfFontEmbedder(document, source).add("Geeza Pro", .regular, [lam + alef + beh]))

        XCTAssertEqual(font.encode(lam + alef + beh).count / 2, 2)
    }
}
#endif
