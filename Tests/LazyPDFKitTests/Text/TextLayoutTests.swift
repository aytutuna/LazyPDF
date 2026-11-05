import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextLayoutTests.cs: the same cases.

final class TextLayoutTests: TextTestCase {
    private func column(_ x: Double, _ top: Double, _ prefix: String, _ lines: Int, _ pitch: Double = 12) -> String {
        var sb = ""
        for i in 0..<lines { sb += line(x, top - Double(i) * pitch, "\(prefix) line \(i + 1) of the column") }
        return sb
    }

    private func offset(_ text: String, _ of: String) -> Int {
        guard let range = text.range(of: of, options: .literal) else { return -1 }
        return text.utf16.distance(from: text.startIndex, to: range.lowerBound)
    }

    func test_linesOfAParagraphJoinWithLineFeeds() throws {
        let page = try text(line(50, 700, "first line here") + line(50, 688, "second line here"))
        XCTAssertEqual(page.text, "first line here\nsecond line here")
        XCTAssertEqual(page.blocks.count, 1)
        XCTAssertEqual(page.lines.count, 2)
    }

    func test_smallLineUnderAHeadingIsNotTakenForAScript() throws {
        let page = try text(line(50, 700, "Questions", 44) + line(50, 678, "Expenses and more", 20))
        XCTAssertEqual(page.lines.count, 2)
        XCTAssertTrue(page.text.contains("Expenses and more"))
        XCTAssertTrue(page.text.hasPrefix("Questions"))
    }

    func test_aBigGapStartsANewBlock() throws {
        let page = try text(line(50, 700, "one") + line(50, 688, "two") + line(50, 650, "three"))
        XCTAssertEqual(page.text, "one\ntwo\n\nthree")
        XCTAssertEqual(page.blocks.count, 2)
    }

    func test_twoColumnsAreReadOneAfterTheOther() throws {
        let page = try self.text(column(50, 700, "left", 6) + column(330, 700, "right", 6))
        let text = page.text
        XCTAssertTrue(offset(text, "left line 6") < offset(text, "right line 1"))
        XCTAssertEqual(page.lines.count, 12)
        XCTAssertTrue(text.hasPrefix("left line 1 of the column\nleft line 2"))
    }

    func test_aNumberInTheGutterDoesNotJoinTheColumns() throws {
        let content = column(50, 700, "left", 8) + column(330, 700, "right", 8) + line(295, 40, "7")
        let text = try self.text(content).text
        XCTAssertTrue(offset(text, "left line 8") < offset(text, "right line 1"))
        XCTAssertTrue(text.hasSuffix("7"))
    }

    func test_aHeadingAcrossBothColumnsComesFirstAndAFootnoteLast() throws {
        let content = line(150, 760, "A heading across the whole page") + column(50, 720, "left", 5) + column(330, 720, "right", 5)
            + line(50, 100, "a note under both columns is long enough to cross the gutter between them")
        let text = try self.text(content).text
        let heading = offset(text, "heading"), left = offset(text, "left line 1")
        let right = offset(text, "right line 1"), note = offset(text, "a note")
        XCTAssertTrue(heading < left && left < right && right < note)
    }

    func test_columnsWhoseParagraphGapsLineUpAreStillReadDownwards() throws {
        let content = column(50, 700, "left a", 3) + column(50, 640, "left b", 3) + column(330, 700, "right a", 3) + column(330, 640, "right b", 3)
        let text = try self.text(content).text
        XCTAssertTrue(offset(text, "left b line 3") < offset(text, "right a line 1"))
    }

    func test_aTableKeepsItsRowsWithTabsBetweenCells() throws {
        var sb = ""
        for row in 0..<4 {
            let y = 600 - Double(row) * 16
            sb += line(50, y, "name\(row)") + line(200, y, "\(row * 11)") + line(350, y, "city\(row)")
        }
        let page = try text(sb)
        XCTAssertEqual(page.text, "name0\t0\tcity0\nname1\t11\tcity1\nname2\t22\tcity2\nname3\t33\tcity3")
        XCTAssertTrue(page.blocks[0].isTable)
    }

    func test_aTwoRowTableOfThreeColumnsIsATable() throws {
        let content = line(50, 600, "a") + line(200, 600, "b") + line(350, 600, "c") + line(50, 584, "d") + line(200, 584, "e") + line(350, 584, "f")
        XCTAssertEqual(try text(content).text, "a\tb\tc\nd\te\tf")
    }

    func test_aSuperscriptStaysOnItsLine() throws {
        let page = try text("BT /F1 10 Tf 100 700 Td (E = mc) Tj /F1 6 Tf 4 Ts (2) Tj ET")
        XCTAssertEqual(page.lines.count, 1)
        XCTAssertEqual(page.text, "E = mc2")
    }

    func test_textInDifferentSizesOnOneBaselineIsOneLine() throws {
        let page = try text("BT /F1 20 Tf 100 700 Td (Big) Tj 8 Tf ( small) Tj ET")
        XCTAssertEqual(page.lines.count, 1)
        XCTAssertEqual(page.text, "Big small")
    }

    func test_readingOrderFollowsPositionNotTheContentStream() throws {
        let page = try text(line(50, 650, "third") + line(50, 700, "first") + line(50, 676, "second"))
        XCTAssertEqual(page.lines.map { $0.text }, ["first", "second", "third"])
    }

    func test_aRotatedPageIsReadAsItIsShown() throws {
        let lines = [(100, "first"), (112, "second"), (124, "third")]
            .map { "BT /F1 10 Tf 0 1 -1 0 \($0.0) 100 Tm (\($0.1) line of text) Tj ET\n" }.joined()
        let page = try text(lines, "/Rotate 90")
        XCTAssertEqual(page.lines.map { $0.text }, ["first line of text", "second line of text", "third line of text"])
        XCTAssertEqual(page.text, "first line of text\nsecond line of text\nthird line of text")
    }

    func test_aTurnedPageGivesTheSameWordsAsTheUpright() throws {
        let upright = try text(line(50, 700, "alpha beta") + line(50, 688, "gamma delta"))
        let turned = try text("BT /F1 10 Tf 0 -1 1 0 62 700 Tm (alpha beta) Tj ET BT /F1 10 Tf 0 -1 1 0 50 700 Tm (gamma delta) Tj ET", "/Rotate 270")
        XCTAssertEqual(upright.words.map { $0.text }, turned.words.map { $0.text })
    }

    func test_verticalWritingRunsDownColumnsFromRightToLeft() throws {
        let cid = "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 1000>>"
        let type0 = "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-V /DescendantFonts [7 0 R] /ToUnicode 8 0 R>>"
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange "
            + "6 beginbfchar <0001> <0041> <0002> <0042> <0003> <0043> <0004> <0044> <0005> <0045> <0006> <0046> endbfchar endcmap"
        let document = try self.page("BT /V 10 Tf 300 700 Td <000100020003> Tj ET BT /V 10 Tf 280 700 Td <000400050006> Tj ET", "/Font <</V 6 0 R>>", "") { pdf in
            pdf.obj(6, type0)
            pdf.obj(7, cid)
            pdf.stream(8, "", cmap)
        }
        let page = TextPage.create(document, document.pages[0])
        XCTAssertEqual(page.text, "ABC\nDEF")
        for l in page.lines { XCTAssertTrue(l.isVertical) }
    }

    func test_rotatedLabelsComeAfterTheMainText() throws {
        let content = "BT /F1 10 Tf 0 1 -1 0 30 300 Tm (side label) Tj ET " + line(100, 700, "main text") + line(100, 688, "more main text")
        let page = try text(content)
        XCTAssertEqual(page.text, "main text\nmore main text\n\nside label")
    }

    func test_largePagesStayFast() throws {
        var sb = ""
        for i in 0..<80 { sb += line(50, 780 - Double(i) * 9, String(repeating: "word ", count: 16), 8) }
        let document = try self.page(sb)
        let start = Date()
        let page = TextPage.create(document, document.pages[0])
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        XCTAssertTrue(elapsed < 1500, "\(elapsed) ms")
        XCTAssertEqual(page.lines.count, 80)
    }
}
