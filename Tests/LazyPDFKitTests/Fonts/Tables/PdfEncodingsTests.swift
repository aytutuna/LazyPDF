import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Tables/PdfEncodingsTests.cs: the same cases. The tables are
// arrays here, which have no identity, so the C# Assert.Same checks are equality checks.

final class PdfEncodingsTests: XCTestCase {
    private let all = [
        PdfEncodings.standard, PdfEncodings.winAnsi, PdfEncodings.macRoman, PdfEncodings.macExpert,
        PdfEncodings.pdfDoc, PdfEncodings.symbol, PdfEncodings.zapfDingbats,
    ]

    func test_tablesHave256Slots() {
        for table in all {
            XCTAssertEqual(table.count, 256)
        }
    }

    func test_standardEncodingKeepsItsQuirks() {
        XCTAssertEqual(PdfEncodings.standard[39], "quoteright")
        XCTAssertEqual(PdfEncodings.standard[96], "quoteleft")
        XCTAssertEqual(PdfEncodings.standard[174], "fi")
        XCTAssertNil(PdfEncodings.standard[127])
    }

    func test_winAnsiMatchesCodePage1252() {
        XCTAssertEqual(PdfEncodings.winAnsi[39], "quotesingle")
        XCTAssertEqual(PdfEncodings.winAnsi[128], "Euro")
        XCTAssertEqual(PdfEncodings.winAnsi[142], "Zcaron")
        XCTAssertEqual(PdfEncodings.winAnsi[233], "eacute")
        XCTAssertEqual(PdfEncodings.winAnsi[255], "ydieresis")
    }

    func test_winAnsiShowsBulletsForUnusedCodes() {
        XCTAssertEqual(PdfEncodings.winAnsi[127], "bullet")
        XCTAssertEqual(PdfEncodings.winAnsi[129], "bullet")
        XCTAssertEqual(PdfEncodings.winAnsi[160], "space")
        XCTAssertEqual(PdfEncodings.winAnsi[173], "hyphen")
    }

    func test_macRomanAndExpert() {
        XCTAssertEqual(PdfEncodings.macRoman[128], "Adieresis")
        XCTAssertEqual(PdfEncodings.macRoman[202], "space")
        XCTAssertEqual(PdfEncodings.macExpert[97], "Asmall")
    }

    func test_pdfDocHasItsAccentsBelowSpace() {
        XCTAssertEqual(PdfEncodings.pdfDoc[24], "breve")
        XCTAssertEqual(PdfEncodings.pdfDoc[25], "caron")
        XCTAssertEqual(PdfEncodings.pdfDoc[160], "Euro")
    }

    func test_builtInEncodingsOfSymbolAndZapfDingbats() {
        XCTAssertEqual(PdfEncodings.symbol[97], "alpha")
        XCTAssertEqual(PdfEncodings.symbol[34], "universal")
        XCTAssertEqual(PdfEncodings.zapfDingbats[33], "a1")
        XCTAssertEqual(PdfEncodings.zapfDingbats[32], "space")
    }

    func test_everyNameResolvesToUnicode() {
        for table in all where table != PdfEncodings.macExpert {
            for case let name? in table {
                XCTAssertNotNil(GlyphList.unicodeOf(name), name)
            }
        }
    }

    func test_byNameAndCodeOf() {
        XCTAssertEqual(PdfEncodings.byName("WinAnsiEncoding"), PdfEncodings.winAnsi)
        XCTAssertNil(PdfEncodings.byName("Identity-H"))
        XCTAssertEqual(PdfEncodings.codeOf(PdfEncodings.winAnsi, "A"), 65)
        XCTAssertEqual(PdfEncodings.codeOf(PdfEncodings.standard, "Euro"), -1)
    }
}
