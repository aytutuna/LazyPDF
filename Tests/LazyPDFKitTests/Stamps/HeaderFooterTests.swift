import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Stamps/HeaderFooterTests.cs: the same cases. The Turkish text is the letters of the
// synthetic font, which has no digits and draws ı as ğ, so the page number of TurkishTextNeedsAndGetsAnEmbeddedFont is the
// file name and the text has no ı. The CultureInfo of ADateFormatFollowsTheCulture is the one of DateTimeFormat.swift.

final class HeaderFooterTests: XCTestCase {
    private let day = DateTimeOffset(2026, 3, 9, 10, 0, 0)

    private func shown(_ document: PdfDocument, _ page: Int) -> String { StampKit.text(StampKit.glyphs(document, page)) }

    func test_theSixSlotsSitInTheirCornersAndCentres() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(
            header: HeaderFooterBand("HL", "HC", "HR"),
            footer: HeaderFooterBand("FL", "FC", "FR"),
            fontSize: 10,
            marginX: 30,
            marginTop: 20,
            marginBottom: 25))
        let glyphs = StampKit.glyphs(document, 0)
        let font = try XCTUnwrap(try PdfFontEmbedder(document).add("Helvetica", .regular, ["HLFRC"]))
        let header = glyphs.filter { $0.y < 100 }
        let footer = glyphs.filter { $0.y > 200 }

        XCTAssertEqual(StampKit.text(header), "HLHCHR")
        XCTAssertEqual(header[0].y, 20 + font.ascent * 10, accuracy: 5e-4)
        XCTAssertEqual(header[0].x, 30, accuracy: 5e-4)
        XCTAssertEqual(header[2].x, 100 - font.width("HC", 10) / 2, accuracy: 5e-4)
        XCTAssertEqual(header[4].x, 200 - 30 - font.width("HR", 10), accuracy: 5e-4)
        XCTAssertEqual(StampKit.text(footer), "FLFCFR")
        XCTAssertEqual(footer[0].y, 300 - 25 + font.descent * 10, accuracy: 5e-4)
        XCTAssertEqual(footer[0].x, 30, accuracy: 5e-4)
    }

    func test_pageNumbersCountFromTheStartNumber() throws {
        let document = try StampKit.doc(3)
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(footer: HeaderFooterBand("", "Page {page} of {pages}", ""), startNumber: 5))
        XCTAssertEqual(shown(document, 0), "Page 5 of 7")
        XCTAssertEqual(shown(document, 2), "Page 7 of 7")
    }

    func test_aNumberPastTheEndOfAnIntWraps() throws {
        let document = try StampKit.doc(2)
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(footer: HeaderFooterBand("", "{page} of {pages}", ""),
                                                                  startNumber: Int(Int32.max)))
        XCTAssertEqual(shown(document, 0), "2147483647 of -2147483648")
        XCTAssertEqual(shown(document, 1), "-2147483648 of -2147483648")
    }

    func test_dateFileAndTheDefaultFormat() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(
            header: HeaderFooterBand("{date}", "{file}", "{date:dd/MM/yyyy}"),
            date: day,
            fileName: "report.pdf"))
        XCTAssertEqual(shown(document, 0), "2026-03-09report.pdf09/03/2026")
    }

    func test_aDateFormatFollowsTheCulture() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(
            header: HeaderFooterBand("", "{date:d MMMM yyyy}", ""),
            date: day,
            culture: CultureInfo("en-GB")))
        XCTAssertEqual(shown(document, 0), "9 March 2026")
    }

    func test_unknownTokensAndBracesStayAsTyped() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(header: HeaderFooterBand("", "{nope} {page", "{bates}")))
        XCTAssertEqual(shown(document, 0), "{nope} {page{bates}")
    }

    func test_evenPagesCanDifferFromOddOnes() throws {
        let document = try StampKit.doc(3)
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(
            header: HeaderFooterBand("", "", "odd"),
            footer: HeaderFooterBand("", "{page}", ""),
            evenHeader: HeaderFooterBand("even", "", "")))
        XCTAssertEqual(shown(document, 0), "odd1")
        XCTAssertEqual(shown(document, 1), "even2")
        XCTAssertEqual(shown(document, 2), "odd3")
        XCTAssertEqual(StampKit.glyphs(document, 1)[0].x, 36, accuracy: 5e-4)
    }

    func test_anEvenFooterAloneKeepsTheHeader() throws {
        let document = try StampKit.doc(2)
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(
            header: HeaderFooterBand("H", "", ""),
            footer: HeaderFooterBand("", "", "odd"),
            evenFooter: HeaderFooterBand("", "", "even")))
        XCTAssertEqual(shown(document, 0), "Hodd")
        XCTAssertEqual(shown(document, 1), "Heven")
    }

    func test_onlyTheChosenPagesAreStamped() throws {
        let document = try StampKit.doc(4)
        let run = try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(footer: HeaderFooterBand("", "{page}", ""), pages: [1, 3]))
        XCTAssertEqual(run.pages, 2)
        XCTAssertEqual(shown(document, 0), "")
        XCTAssertEqual(shown(document, 1), "2")
        XCTAssertEqual(shown(document, 3), "4")
    }

    func test_pagesWithNothingToShowAreSkipped() throws {
        let document = try StampKit.doc(2)
        let run = try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(header: HeaderFooterBand("", "", "x"), evenHeader: HeaderFooterBand()))
        XCTAssertEqual(run.pages, 1)
        XCTAssertTrue(PdfStamper(document).list(document.pages[1]).isEmpty)
    }

    func test_rotatedPagesKeepTheTextUprightAndInPlace() throws {
        for rotate in [0, 90, 180, 270] {
            let document = try StampKit.pages([(keys: "/Rotate \(rotate)", content: "BT /F1 12 Tf 50 50 Td (p) Tj ET")])
            try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(header: HeaderFooterBand("", "AB", ""), footer: HeaderFooterBand("CD", "", "")))
            let geometry = PageGeometry(document.pages[0])
            let glyphs = StampKit.glyphs(document, 0)
            for g in glyphs {
                XCTAssertEqual(g.dirX, 1, accuracy: 5e-7, "rotate \(rotate)")
                XCTAssertEqual(g.dirY, 0, accuracy: 5e-7, "rotate \(rotate)")
            }
            let head = glyphs.filter { $0.text == "A" || $0.text == "B" }
            let font = try XCTUnwrap(try PdfFontEmbedder(document).add("Helvetica", .regular, ["AB"]))
            XCTAssertEqual(head[0].y, head[1].y, accuracy: 5e-7, "rotate \(rotate)")
            XCTAssertTrue(head[0].y < 60, "rotate \(rotate)")
            XCTAssertEqual(head[0].x, geometry.width / 2 - font.width("AB", 10) / 2, accuracy: 5e-4, "rotate \(rotate)")
            let foot = try XCTUnwrap(glyphs.first { $0.text == "C" })
            XCTAssertTrue(foot.y > geometry.height - 60, "rotate \(rotate)")
            XCTAssertEqual(foot.x, 36, accuracy: 5e-4, "rotate \(rotate)")
        }
    }

    func test_turkishTextNeedsAndGetsAnEmbeddedFont() throws {
        let document = try StampKit.doc(2)
        let text = "AB ğİ {file}"
        XCTAssertThrowsError(try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(footer: HeaderFooterBand("", text, ""), fileName: "BA"))) { error in
            XCTAssertTrue(error is InvalidOperationException)
        }
        let run = try PdfStamper(document, try ArialSource()).addHeaderFooter(HeaderFooterSpec(footer: HeaderFooterBand("", text, ""), fileName: "BA"))
        XCTAssertTrue(run.missing.isEmpty)
        let reopened = try PdfDocument.open(try StampKit.rewrite(document))
        XCTAssertEqual(shown(reopened, 1), "AB ğİ BA")
    }

    func test_colourSizeAndStyleAreUsed() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(
            header: HeaderFooterBand("", "x", ""),
            fontStyle: .bold,
            fontSize: 18,
            color: StampColor(1, 0, 0)))
        XCTAssertEqual(StampKit.glyphs(document, 0)[0].size, 18, accuracy: 5e-7)
        XCTAssertTrue(StampKit.latin(document, 0).contains("1 0 0 rg"))
        let font = try XCTUnwrap(document.dict(document.dict(document.pages[0].resources, "Font"), "LPS1_F"))
        XCTAssertEqual(document.name(font, "BaseFont"), "Helvetica-Bold")
    }

    func test_userUnitScalesTheMarginsAndTextBackToPoints() throws {
        let document = try StampKit.pages([(keys: "/UserUnit 2", content: "BT /F1 12 Tf 50 50 Td (u) Tj ET")])
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(header: HeaderFooterBand("W", "", ""), marginX: 20))
        let glyph = StampKit.glyphs(document, 0)[0]
        XCTAssertEqual(glyph.x, 20, accuracy: 5e-4)
        XCTAssertEqual(glyph.size, 10, accuracy: 5e-7)
    }

    func test_aCropBoxIsTheEdgeOfThePage() throws {
        let document = try StampKit.pages([(keys: "/CropBox [10 20 110 220]", content: "BT /F1 12 Tf 50 50 Td (c) Tj ET")])
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(footer: HeaderFooterBand("L", "", "R"), marginX: 15, marginBottom: 10))
        let glyphs = StampKit.glyphs(document, 0)
        let font = try XCTUnwrap(try PdfFontEmbedder(document).add("Helvetica", .regular, ["LR"]))
        XCTAssertEqual(glyphs[0].x, 15, accuracy: 5e-4)
        XCTAssertEqual(glyphs[1].x, 100 - 15 - font.width("R", 10), accuracy: 5e-4)
        XCTAssertEqual(glyphs[0].y, 200 - 10 + font.descent * 10, accuracy: 5e-4)
    }
}
