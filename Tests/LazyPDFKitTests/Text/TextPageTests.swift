import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextPageTests.cs: the same cases.

final class TextPageTests: TextTestCase {

    func test_glyphsBecomeCharactersWithBoxes() throws {
        let page = try text("0 0 1 rg " + line(100, 700, "Hi"))
        XCTAssertEqual(page.text, "Hi")
        XCTAssertEqual(page.chars.count, 2)
        let c = page.chars[1]
        XCTAssertEqual(c.text, "i")
        XCTAssertEqual(c.size, 10, accuracy: 1e-6)
        XCTAssertEqual(c.quad.x0, 105, accuracy: 1e-6)
        XCTAssertEqual(c.quad.x1, 110, accuracy: 1e-6)
        XCTAssertTrue(c.quad.y0 < 700 && c.quad.y3 > 700)
        XCTAssertEqual(c.color, RgbColor(0, 0, 255))
        XCTAssertEqual(c.font?.name, "Helvetica")
    }

    func test_spaceGlyphsAndGapsMakeWords() throws {
        let page = try text("BT /F1 10 Tf 100 700 Td [(ab) -600 (cd)] TJ ( ef) Tj ET")
        XCTAssertEqual(page.words.map { $0.text }, ["ab", "cd", "ef"])
        XCTAssertTrue(page.chars.contains { $0.isImplied && $0.text == " " })
        XCTAssertTrue(page.chars.contains { $0.isSpace && !$0.isImplied })
        XCTAssertEqual(page.text, "ab cd ef")
    }

    func test_aTightKernDoesNotSplitAWord() throws {
        let page = try text("BT /F1 10 Tf 100 700 Td [(A) 60 (V) -50 (A)] TJ ET")
        XCTAssertEqual(page.words.count, 1)
    }

    func test_ligatureIsOneGlyphWithSeveralCharacters() throws {
        let page = try text(line(100, 700, #"\001nd"#), "", (1, "fi"))
        XCTAssertEqual(page.text, "find")
        XCTAssertEqual(page.chars.count, 3)
        XCTAssertEqual(page.chars[0].text, "fi")
        XCTAssertEqual(page.chars[0].quad.x1 - page.chars[0].quad.x0, 5, accuracy: 1e-6)
    }

    func test_presentationFormsBecomePlainLetters() throws {
        let page = try text(line(100, 700, #"\001\002"#), "", (1, "\u{FB01}"), (2, "\u{FEED}"))
        XCTAssertEqual(page.text, "fi\u{0648}")
    }

    func test_invisibleOcrTextIsIncludedAndClipOnlyTextIsNot() throws {
        let page = try text("BT /F1 10 Tf 3 Tr 100 700 Td (ocr) Tj 7 Tr (gone) Tj ET")
        XCTAssertEqual(page.text, "ocr")
        for c in page.chars { XCTAssertEqual(c.renderMode, 3) }
    }

    func test_clippedAwayAndOffPageTextIsLeftOut() throws {
        let content = "q 0 0 50 50 re W n " + line(200, 700, "clipped") + "Q " + line(-300, 700, "off") + line(100, 100, "kept")
        XCTAssertEqual(try text(content).text, "kept")
    }

    func test_textPartlyInsideTheClipStays() throws {
        let content = "q 100 690 22 30 re W n " + line(100, 700, "abcdefgh") + "Q"
        XCTAssertEqual(try text(content).text, "abcde")
    }

    func test_artifactsCanBeLeftOut() throws {
        let content = line(100, 700, "body") + "/Artifact BMC " + line(100, 50, "footer") + "EMC"
        let document = try self.page(content)
        let all = TextPage.create(document, document.pages[0])
        XCTAssertEqual(all.text, "body\n\nfooter")
        XCTAssertEqual(all.lines.map { all.chars[$0.range.start].isArtifact }, [false, true])
        let page = TextPage.create(document, document.pages[0], TextPageOptions(includeArtifacts: false))
        XCTAssertEqual(page.text, "body")
    }

    func test_actualTextReplacesTheGlyphs() throws {
        let content = "/Span <</ActualText (Hello)>> BDC " + line(100, 700, "xyz") + "EMC " + line(100, 650, "after")
        let page = try text(content)
        XCTAssertEqual(page.text, "Hello\n\nafter")
        let first = page.chars[0]
        XCTAssertEqual(first.text, "Hello")
        XCTAssertEqual(first.quad.x0, 100, accuracy: 1e-6)
        XCTAssertEqual(first.quad.x1, 115, accuracy: 1e-6)
    }

    func test_actualTextInUtf16IsRead() throws {
        let content = "/Span <</ActualText <FEFF00E900E8>>> BDC " + line(100, 700, "ab") + "EMC"
        XCTAssertEqual(try text(content).text, "\u{E9}\u{E8}")
    }

    func test_emptyActualTextHidesTheGlyphs() throws {
        let content = "/Span <</ActualText ()>> BDC " + line(100, 700, "xyz") + "EMC " + line(100, 650, "kept")
        XCTAssertEqual(try text(content).text, "kept")
    }

    func test_glyphDrawnTwiceForBoldIsKeptOnce() throws {
        let content = line(100, 700, "Bold") + line(100.4, 700, "Bold")
        XCTAssertEqual(try text(content).text, "Bold")
        let document = try self.page(content)
        let raw = TextPage.create(document, document.pages[0], TextPageOptions(removeDuplicates: false))
        XCTAssertEqual(raw.chars.count, 8)
    }

    func test_repeatedLettersNextToEachOtherSurvive() throws {
        XCTAssertEqual(try text(line(100, 700, "ll")).text, "ll")
    }

    func test_glyphsWithoutTextKeepTheirBoxes() throws {
        let page = try text(line(100, 700, #"a\001b"#), "", (1, ""))
        XCTAssertEqual(page.chars.count, 3)
        XCTAssertEqual(page.text, "ab")
        XCTAssertEqual(page.words.count, 1)
    }

    func test_formTextKnowsItsFormAndOperator() throws {
        let document = try self.page("/Fm Do " + line(100, 600, "page"), "/Font <</F1 5 0 R>> /XObject <</Fm 7 0 R>>", "") { pdf in
            self.font(pdf, 5)
            pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", self.line(100, 700, "form"))
        }
        let page = TextPage.create(document, document.pages[0])
        let inForm = try XCTUnwrap(page.chars.first { $0.text == "f" })
        let onPage = try XCTUnwrap(page.chars.first { $0.text == "p" })
        XCTAssertNotNil(inForm.form)
        XCTAssertNil(onPage.form)
        XCTAssertEqual(onPage.operatorIndex, 4)
        XCTAssertEqual(inForm.operatorIndex, 3)
    }

    func test_operatorElementAndOffsetLocateTheGlyph() throws {
        let page = try text("BT /F1 10 Tf 100 700 Td [(ab) 5 (cd)] TJ ET")
        let d = try XCTUnwrap(page.chars.first { $0.text == "d" })
        XCTAssertEqual(d.element, 2)
        XCTAssertEqual(d.offset, 1)
        XCTAssertEqual(d.operatorIndex, page.chars[0].operatorIndex)
    }

    func test_rotatedTextKeepsItsSlantInUserSpace() throws {
        let page = try text("BT /F1 10 Tf 0 1 -1 0 300 300 Tm (up) Tj ET")
        let q = page.chars[0].quad
        XCTAssertEqual(q.y0, q.y3, accuracy: 1e-6)
        XCTAssertTrue(q.y1 > q.y0)
        XCTAssertEqual(page.text, "up")
    }

    func test_emptyAndBrokenContentGiveAnEmptyPage() throws {
        XCTAssertTrue(try text("").chars.isEmpty)
        XCTAssertEqual(try text("(((( << [ BT ET Tj").text, "")
    }

    func test_zeroSizeTextIsIgnored() throws {
        XCTAssertEqual(try text("BT /F1 0 Tf 100 700 Td (x) Tj ET").text, "")
    }
}
