import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/FreeTextTests.cs: the same cases. The C# source reads Arial from the
// Windows fonts folder; here it is the synthetic font, which has A, B, space, ğ, ı, İ and À, so the Turkish sentence is
// made of those.

final class FreeTextTests: XCTestCase {
    private let turkish = "AB ğİ BA"

    private func start(_ fonts: FontSource? = nil) throws -> (document: PdfDocument, writer: PdfAnnotationWriter, page: PdfPage) {
        let document = try AnnotationFixtures.blank()
        return (document, PdfAnnotationWriter(document, fonts), document.pages[0])
    }

    private func fonts(_ document: PdfDocument, _ annotation: PdfAnnotation) throws -> [PdfDictionary] {
        let resources = document.dict(try AnnotationFixtures.normal(document, annotation).dictionary, "Resources")
        let entries = try XCTUnwrap(document.dict(resources, "Font")).entries
        return entries.compactMap { document.resolve($0.value) as? PdfDictionary }
    }

    func test_englishTextUsesAStandardFontWithoutASource() throws {
        let (document, writer, page) = try start()
        let box = try writer.addFreeText(page, PdfRect(100, 600, 300, 640), "Hello, World (café)", info: AnnotationInfo(author: "Ayşe"))
        XCTAssertEqual(try AnnotationFixtures.draw(document, box).text, "Hello, World (café)")
        let list = try fonts(document, box)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(document.name(list[0], "Subtype"), "Type1")
        XCTAssertEqual(box.contents, "Hello, World (café)")
        XCTAssertEqual(document.name(box.dictionary, "IT"), "FreeText")
    }

    func test_turkishTextEmbedsAFontFromTheSource() throws {
        let (document, writer, page) = try start(try AnnotationFixtures.ArialSource())
        let box = try writer.addFreeText(page, PdfRect(100, 600, 500, 640), turkish, font: FreeTextStyle(family: "Arial", size: 14))
        XCTAssertEqual(try AnnotationFixtures.draw(document, box).text, turkish)
        let list = try fonts(document, box)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(document.name(list[0], "Subtype"), "Type0")
        XCTAssertEqual(box.contents, turkish)
        try AnnotationFixtures.reopen(document)
    }

    private final class CjkSource: FontSource {
        private let lacking: [UInt8]
        private let covering: [UInt8]?

        init(covering: Bool) throws {
            lacking = try SyntheticFonts.onlyA()
            self.covering = covering ? try SyntheticFonts.ttf() : nil
        }

        func find(_ family: String, _ style: FontStyles) -> FontFile? {
            if family == "Microsoft YaHei", let covering { return FontFile(covering) }
            return FontFile(lacking)
        }
    }

    func test_textTheFontLacksIsDrawnInAFallbackFont() throws {
        let (document, writer, page) = try start(try CjkSource(covering: true))
        let box = try writer.addFreeText(page, PdfRect(100, 600, 400, 640), turkish, font: FreeTextStyle(family: "Arial", size: 14))
        XCTAssertEqual(try AnnotationFixtures.draw(document, box).text, turkish)
        XCTAssertEqual(try fonts(document, box).count, 1)
        XCTAssertEqual(writer.takeUndrawn(), "")
    }

    func test_aRunThatFitsItsFamilyKeepsItWhenAnotherRunNeedsAFallback() throws {
        let (document, writer, page) = try start(try CjkSource(covering: true))
        let rich = "<body xmlns=\"http://www.w3.org/1999/xhtml\"><p><span style=\"font-family:Times New Roman\">AB</span><span style=\"font-family:Microsoft YaHei\">ğİ</span></p></body>"
        let box = try writer.addFreeText(page, PdfRect(100, 600, 400, 640), "", font: FreeTextStyle(richText: rich))
        XCTAssertEqual(try AnnotationFixtures.draw(document, box).text, "ABğİ")
        XCTAssertEqual(try fonts(document, box).compactMap { document.name($0, "Subtype") }.sorted(), ["Type0", "Type1"])
        XCTAssertEqual(writer.takeUndrawn(), "")
    }

    func test_charactersNoFontHasAreReportedOnce() throws {
        let (document, writer, page) = try start(try CjkSource(covering: false))
        let box = try writer.addFreeText(page, PdfRect(100, 600, 400, 640), "BğBğ", font: FreeTextStyle(family: "Arial", size: 14))
        XCTAssertEqual(writer.takeUndrawn(), "Bğ")
        XCTAssertEqual(writer.takeUndrawn(), "")
        XCTAssertEqual(document.name(try fonts(document, box)[0], "Subtype"), "Type0")
    }

    func test_turkishTextWithoutAFontSourceSaysSo() throws {
        let (_, writer, page) = try start()
        XCTAssertThrowsError(try writer.addFreeText(page, PdfRect(100, 600, 500, 640), turkish)) {
            XCTAssertEqual(($0 as? InvalidOperationException)?.message, AnnotationText.noFont)
        }
    }

    func test_textWrapsAtTheWidthOfTheBox() throws {
        let (document, writer, page) = try start()
        let box = try writer.addFreeText(page, PdfRect(100, 500, 220, 600), "The quick brown fox jumps over the lazy dog and keeps running", font: FreeTextStyle(size: 12))
        let glyphs = try AnnotationFixtures.draw(document, box).glyphs
        let lines = Set(glyphs.map { ($0.bounds.bottom * 10).rounded(.toNearestOrEven) / 10 })
        XCTAssertTrue(lines.count >= 4, "\(lines.count) lines")
        for g in glyphs { XCTAssertTrue(g.bounds.right <= 120 - 2 + 0.01, "a glyph runs out of the box") }
        XCTAssertEqual(glyphs.map { $0.unicode ?? "" }.joined().replacingOccurrences(of: " ", with: ""), "Thequickbrownfoxjumpsoverthelazydogandkeepsrunning")
    }

    func test_longWordsBreakAtTheCharacterAndNewlinesStay() throws {
        let (document, writer, page) = try start()
        let box = try writer.addFreeText(page, PdfRect(100, 500, 160, 700), "Supercalifragilisticexpialidocious\nnext")
        let glyphs = try AnnotationFixtures.draw(document, box).glyphs
        for g in glyphs { XCTAssertTrue(g.bounds.right <= 60 - 2 + 0.01) }
        XCTAssertEqual(glyphs.map { $0.unicode ?? "" }.joined(), "Supercalifragilisticexpialidociousnext")
        XCTAssertTrue(try XCTUnwrap(glyphs.last).bounds.bottom < (try XCTUnwrap(glyphs.first)).bounds.bottom)
    }

    func test_alignmentMovesTheLine() throws {
        for alignment in 0...2 {
            let (document, writer, page) = try start()
            let box = try writer.addFreeText(page, PdfRect(100, 600, 300, 640), "Hi", font: FreeTextStyle(alignment: alignment))
            let glyphs = try AnnotationFixtures.draw(document, box).glyphs
            let left = try XCTUnwrap(glyphs.first).bounds.left, right = try XCTUnwrap(glyphs.last).bounds.right
            switch alignment {
            case 0: XCTAssertEqual(left, 2, accuracy: 0.05)
            case 1: XCTAssertEqual((left + right) / 2, 100, accuracy: 0.05)
            default: XCTAssertEqual(right, 198, accuracy: 0.05)
            }
            XCTAssertEqual(box.alignment, alignment)
        }
    }

    func test_textIsClippedToTheBox() throws {
        let (document, writer, page) = try start()
        let box = try writer.addFreeText(page, PdfRect(100, 600, 160, 620), Array(repeating: "overflow", count: 30).joined(separator: " "))
        let ops = AnnotationFixtures.operators(try AnnotationFixtures.appearance(document, box))
        XCTAssertTrue(ops.contains("W"))
        XCTAssertTrue(ops.filter { $0 == "Tj" }.count < 30, "lines far below the box are not written")
    }

    func test_borderAndFillAreDrawnBehindTheText() throws {
        let (document, writer, page) = try start()
        let box = try writer.addFreeText(page, PdfRect(100, 600, 300, 640), "boxed", style: AnnotationStyle(color: [1, 0, 0], width: 2, fill: [1, 1, 0.8]))
        let ops = AnnotationFixtures.operators(try AnnotationFixtures.appearance(document, box))
        let fill = try XCTUnwrap(ops.firstIndex(of: "f")), stroke = try XCTUnwrap(ops.firstIndex(of: "S")), text = try XCTUnwrap(ops.firstIndex(of: "BT"))
        XCTAssertTrue(fill < stroke)
        XCTAssertTrue(stroke < text)
        XCTAssertEqual(box.interiorColor, [1, 1, 0.8])
    }

    func test_calloutGrowsTheAnnotationAndKeepsTheBoxInRd() throws {
        let (document, writer, page) = try start()
        let text = PdfRect(300, 600, 400, 640)
        let box = try writer.addFreeText(page, text, "see here", style: AnnotationStyle(color: [0, 0, 0], width: 1),
                                         callout: [(100, 500), (200, 500), (300, 620)])
        XCTAssertEqual(box.intent, "FreeTextCallout")
        XCTAssertEqual(box.callout.count, 6)
        XCTAssertEqual(box.startEnding, .openArrow)
        XCTAssertTrue(box.rect.left < 100 && box.rect.bottom < 500 && box.rect.right >= 400 && box.rect.top >= 640)
        XCTAssertEqual(box.rectDifference.count, 4)
        XCTAssertEqual(box.rect.left + box.rectDifference[0], text.left, accuracy: 5e-4)
        XCTAssertEqual(box.rect.top - box.rectDifference[3], text.top, accuracy: 5e-4)
        let recorder = try AnnotationFixtures.draw(document, box)
        XCTAssertEqual(recorder.text, "see here")
        XCTAssertTrue(recorder.paths.count >= 3, "box border, callout line and arrow")
        XCTAssertThrowsError(try writer.addFreeText(page, text, "x", callout: [(1, 1)])) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_richTextKeepsBoldAndColour() throws {
        let (document, writer, page) = try start()
        let rich = "<body xmlns=\"http://www.w3.org/1999/xhtml\" style=\"font-size:12pt;font-family:Helvetica\"><p>plain <span style=\"font-weight:bold;color:#FF0000\">loud</span> <i>slanted</i></p><p>second</p></body>"
        let box = try writer.addFreeText(page, PdfRect(100, 600, 400, 660), "", font: FreeTextStyle(richText: rich))
        XCTAssertEqual(box.contents, "plain loud slanted\nsecond")
        XCTAssertEqual(box.richText, rich)
        let recorder = try AnnotationFixtures.draw(document, box)
        XCTAssertEqual(recorder.text, "plain loud slantedsecond")
        let names = try fonts(document, box).map { document.name($0, "BaseFont") }
        XCTAssertTrue(names.contains("Helvetica-Bold"))
        XCTAssertTrue(names.contains("Helvetica-Oblique"))
        XCTAssertTrue(try AnnotationFixtures.appearance(document, box).contains { $0.operator == "rg" && $0.number(0) == 1 && $0.number(1) == 0 })
        XCTAssertEqual(Set(recorder.glyphs.map { $0.bounds.bottom.rounded(.toNearestOrEven) }).count, 2)
    }

    func test_brokenRichTextFallsBackToTheContents() throws {
        let (document, writer, page) = try start()
        let box = try writer.addFreeText(page, PdfRect(100, 600, 400, 660), "plain words", font: FreeTextStyle(richText: "<body><p>unclosed"))
        XCTAssertEqual(try AnnotationFixtures.draw(document, box).text, "plain words")
    }

    func test_fontAndColourAreKeptInDaAndDs() throws {
        let (document, writer, page) = try start()
        let box = try writer.addFreeText(page, PdfRect(100, 600, 400, 660), "x", font: FreeTextStyle(family: "Times New Roman", size: 18, font: [.bold, .italic], textColor: [0, 0, 1]))
        XCTAssertEqual(box.defaultAppearance, "/TiBI 18 Tf 0 0 1 rg")
        XCTAssertTrue((box.defaultStyle ?? "").contains("font-family: Times New Roman"))
        let list = try fonts(document, box)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(document.name(list[0], "BaseFont"), "Times-BoldItalic")
        let reread = PdfAnnotations.read(try AnnotationFixtures.reopen(document), document.pages[0])
        XCTAssertEqual(reread.first?.defaultAppearance, box.defaultAppearance)
    }

    func test_noteIconIsDrawnForOtherViewers() throws {
        let (document, writer, page) = try start()
        let note = try writer.addNote(page, PdfRect(100, 700, 120, 720), AnnotationInfo(author: "A", contents: "remember"), icon: "Comment")
        XCTAssertEqual(note.iconName, "Comment")
        XCTAssertTrue(note.flags.contains(.noZoom))
        XCTAssertTrue(AnnotationFixtures.operators(try AnnotationFixtures.appearance(document, note)).contains("B"))
    }
}
