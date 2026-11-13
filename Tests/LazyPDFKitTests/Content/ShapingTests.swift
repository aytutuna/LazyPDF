import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/ShapingTests.cs, with the font the Windows tests build, read from
// Tests/Fixtures/golden/shaping/script.ttf.

final class ShapingTests: XCTestCase {
    private static let font: [UInt8] = (try? ShapingGolden.font()) ?? []
    private static let measure = TrueTypeFont.tryParse(font)!
    // The three glyphs no cmap entry reaches come last in the font, lam-alef first.
    private static let lamAlef = measure.glyphCount - 3

    private final class ScriptFonts: FontSource {
        var requests: [String] = []
        func find(_ family: String, _ style: FontStyles) -> FontFile? {
            requests.append(family)
            return FontFile(ShapingTests.font)
        }
    }

    // Lam followed by alef is one glyph; every other character goes through the cmap.
    private final class LamAlefShaper: Shaper {
        func shape(_ text: String, _ font: FontFile, rightToLeft: Bool, language: String?) -> [ShapedGlyph]? {
            let f = TrueTypeFont.tryParse(font.data)!
            let units = Array(text.utf16)
            var glyphs: [ShapedGlyph] = []
            var i = 0
            while i < units.count {
                if units[i] == 0x0644 && i + 1 < units.count && units[i + 1] == 0x0627 {
                    glyphs.append(ShapedGlyph(glyph: ShapingTests.lamAlef, advance: 900, xOffset: 0, yOffset: 0, cluster: i))
                    i += 2
                    continue
                }
                let gid = f.glyphForCodePoint(Int(units[i]))
                glyphs.append(ShapedGlyph(glyph: gid, advance: Double(f.getAdvance(gid)), xOffset: 0, yOffset: 0, cluster: i))
                i += 1
            }
            if rightToLeft { glyphs.reverse() }
            return glyphs
        }
    }

    // Raises every glyph and nudges it right, as a mark would be placed.
    private final class OffsetShaper: Shaper {
        func shape(_ text: String, _ font: FontFile, rightToLeft: Bool, language: String?) -> [ShapedGlyph]? {
            CmapShaper().shape(text, font, rightToLeft: rightToLeft, language: language)!.map {
                ShapedGlyph(glyph: $0.glyph, advance: $0.advance + 20, xOffset: 50, yOffset: 100, cluster: $0.cluster)
            }
        }
    }

    private final class ShaperAndFonts: FontSource, Shaper {
        var calls = 0
        func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(ShapingTests.font) }
        func shape(_ text: String, _ font: FontFile, rightToLeft: Bool, language: String?) -> [ShapedGlyph]? {
            calls += 1
            return CmapShaper().shape(text, font, rightToLeft: rightToLeft, language: language)
        }
    }

    // The family asked for has no Hebrew; the script fallbacks give a font that has.
    private final class OnlySegoe: FontSource {
        var requests: [String] = []
        func find(_ family: String, _ style: FontStyles) -> FontFile? {
            requests.append(family)
            return family == "Calibri" ? FontFile((try? ProgramsGolden.fixture("synthetic.ttf")) ?? []) : FontFile(ShapingTests.font)
        }
    }

    private func g(_ scalar: Unicode.Scalar) -> Int { Self.measure.glyphForCodePoint(Int(scalar.value)) }

    private func lines(_ shaper: Shaper? = nil) -> LineShaper {
        LineShaper(FontFile(Self.font), shaper ?? CmapShaper(), Self.measure, nil)
    }

    private func glyphs(_ line: ShapedLine) -> [Int] { line.glyphs.map { $0.shaped.glyph } }

    private func visual(_ line: ShapedLine) -> String {
        String(decoding: line.glyphs.flatMap { Array(line.units[$0.start..<$0.end]) }, as: UTF16.self)
    }

    private func blank() throws -> PdfDocument { try PdfDocument.open(TestPdf.simple(1)) }

    private func embed(_ text: String, _ shaper: Shaper? = nil) throws -> PdfDrawFont {
        try XCTUnwrap(try PdfFontEmbedder(try blank(), ScriptFonts(), shaper).add("Script Sans", [], [text]))
    }

    private func content(_ write: (ContentWriter) -> Void) -> String {
        let writer = ContentWriter()
        write(writer)
        return Latin1.string(writer.toArray())
    }

    func test_hebrewIsShownRightToLeft() {
        let line = lines().shape("אבג")
        XCTAssertEqual(glyphs(line), [g("ג"), g("ב"), g("א")])
        XCTAssertTrue(line.rightToLeft)
        XCTAssertFalse(line.needsActualText)
        XCTAssertEqual(line.width, line.glyphs.reduce(0.0) { $0 + $1.shaped.advance })
    }

    func test_latinAndDigitsInsideHebrewKeepTheirOrder() {
        XCTAssertEqual(visual(lines().shape("אב abc 12 גד")), "דג abc 12 בא")
        XCTAssertEqual(visual(lines().shape("אב 12 גד")), "דג 12 בא")
    }

    func test_bracketsAreMirroredInRightToLeftText() {
        let line = lines().shape("אב (גד)")
        XCTAssertEqual(glyphs(line), [g("("), g("ד"), g("ג"), g(")"), g(" "), g("ב"), g("א")])
        XCTAssertTrue(line.needsActualText)
    }

    func test_aMarkStaysAfterItsLetter() {
        XCTAssertEqual(glyphs(lines().shape("אבְ")), [g("ב"), g("\u{05B0}"), g("א")])
    }

    func test_latinTextIsLeftToRightAndNeedsNothing() {
        let line = lines().shape("abc 12")
        XCTAssertEqual(visual(line), "abc 12")
        XCTAssertFalse(line.rightToLeft)
        XCTAssertFalse(line.needsActualText)
    }

    func test_aBaseDirectionCanBeGiven() {
        XCTAssertEqual(visual(lines().shape("abc!", 1)), "!abc")
        XCTAssertEqual(visual(lines().shape("abc!", 0)), "abc!")
        XCTAssertEqual(visual(lines().shape("אב!", 0)), "בא!")
    }

    func test_controlCharactersAndDirectionMarksTakeNoGlyph() {
        XCTAssertEqual(glyphs(lines().shape("\u{200F}א\tב\u{200E}")), [g("ב"), g("א")])
    }

    func test_aRunCanBeShapedInTheDirectionTheLayoutResolved() {
        XCTAssertEqual(glyphs(lines().shapeRun("אבג", rightToLeft: true)), [g("ג"), g("ב"), g("א")])
        XCTAssertEqual(glyphs(lines().shapeRun("אבג", rightToLeft: false)), [g("א"), g("ב"), g("ג")])
    }

    func test_wrapBreaksOnLogicalTextAndKeepsTheParagraphDirection() throws {
        let text = "אבג דהו abc זחט"
        let font = try embed(text)
        let wrapped = font.wrap(text, 10, font.width("אבג", 10) * 2.2)
        XCTAssertGreaterThanOrEqual(wrapped.count, 2)
        for line in wrapped { XCTAssertTrue(font.isRightToLeft(line)) }
        let strip: (String) -> String = { String($0.unicodeScalars.filter { $0 != "\u{200F}" && $0 != " " }) }
        XCTAssertEqual(strip(text), wrapped.map(strip).joined())
    }

    func test_wrapOfPlainTextIsUntouched() throws {
        let font = try embed("abc def ghi")
        XCTAssertEqual(font.wrap("abc def ghi", 10, font.width("abc def", 10) + 1), ["abc def", "ghi"])
    }

    func test_wrapGivenADirectionMarksEveryLineThatDiffers() throws {
        let font = try embed("abc def")
        XCTAssertEqual(font.wrap("abc def", 10, font.width("abc", 10) + 1, rightToLeft: true), ["\u{200F}abc", "\u{200F}def"])
    }

    func test_forcedRightToLeftStillDrawsTheBracketsOfPlainText() throws {
        let font = try embed("a (b)")
        let bytes = font.encode("\u{200F}a (b)")
        XCTAssertEqual(bytes.count, 10)
        for i in stride(from: 0, to: bytes.count, by: 2) { XCTAssertNotEqual(Int(bytes[i]) << 8 | Int(bytes[i + 1]), 0) }
    }

    func test_showWritesHebrewInDisplayOrderWithoutActualText() throws {
        let font = try embed("אבג")
        let text = content { $0.show(font, "אבג", 12) }
        XCTAssertFalse(text.contains("ActualText"))
        let hex = font.encode("אבג").map { String(format: "%02X", $0) }.joined()
        XCTAssertTrue(text.contains("<\(hex)> Tj"))
        XCTAssertEqual(font.encode("אבג").count, 6)
        XCTAssertNotEqual(font.encode("גבא"), font.encode("אבג"))
    }

    func test_aLigatureGetsAToUnicodeEntryOfTwoCodePointsAndActualText() throws {
        let text = "لا ب"
        let document = try blank()
        let font = try XCTUnwrap(try PdfFontEmbedder(document, ScriptFonts(), LamAlefShaper()).add("Script Sans", [], [text]))

        let line = lines(LamAlefShaper()).shape(text)
        XCTAssertEqual(line.glyphs.count, 3)
        XCTAssertTrue(line.needsActualText)

        let shown = content { $0.show(font, text, 12) }
        XCTAssertTrue(shown.contains("/Span <</ActualText <FEFF0644062700200628>>> BDC"))
        XCTAssertTrue(shown.hasSuffix("EMC\n"))

        // The ligature glyph reads back as both letters through the ToUnicode map.
        let page = document.pages[0]
        let name = ContentResources.add(document, ContentResources.forEdit(document, page), "Font", font.reference, "F")
        page.dictionary["Contents"] = try document.add(PdfStream(PdfDictionary(), data: ContentWriter().beginText().font(name, 12).show(font, text, 12).endText().toArray()))
        let reopened = try PdfDocument.open(try document.saveRewrite())
        let fonts = try XCTUnwrap(reopened.dict(reopened.pages[0].resources, "Font"))
        let ours = PdfFont.get(reopened, try XCTUnwrap(reopened.resolve(fonts.entries[0].value) as? PdfDictionary))
        XCTAssertEqual(ours.toText(font.encode("لا")), "لا")
    }

    func test_offsetsAndAdvancesBecomeTjAdjustmentsAndRises() throws {
        let font = try embed("ab", OffsetShaper())
        let text = content { $0.show(font, "ab", 10) }
        XCTAssertTrue(text.hasPrefix("1 Ts\n[-50 <"), text)
        XCTAssertTrue(text.contains("> -20 <"), text)
        XCTAssertTrue(text.hasSuffix("0 Ts\n"), text)
    }

    func test_theFontSourceCanBeTheShaperToo() throws {
        let source = ShaperAndFonts()
        let font = try XCTUnwrap(try PdfFontEmbedder(try blank(), source).add("Script Sans", [], ["ab"]))
        XCTAssertEqual(font.encode("ab").count, 4)
        XCTAssertGreaterThan(source.calls, 0)
    }

    func test_hebrewFallsBackToAFontThatHasIt() throws {
        let source = OnlySegoe()
        let font = try XCTUnwrap(try PdfFontEmbedder(try blank(), source).add("Calibri", [], ["אב"]))
        XCTAssertTrue(font.missing.isEmpty)
        XCTAssertEqual(source.requests, ["Calibri", "Segoe UI"])
    }

    func test_latinOnlyTextAsksForTheFamilyAlone() throws {
        let source = ScriptFonts()
        _ = try PdfFontEmbedder(try blank(), source).add("Script Sans", [], ["abc"])
        XCTAssertEqual(source.requests, ["Script Sans"])
    }
}
