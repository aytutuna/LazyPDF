import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Tables/Standard14Tests.cs: the same cases. The tables are arrays
// here, which have no identity, so the C# Assert.Same checks are equality checks.

final class Standard14Tests: XCTestCase {
    func test_hasFourteenFonts() {
        XCTAssertEqual(Standard14.all.count, 14)
        XCTAssertEqual(Set(Standard14.all.map { $0.name }).count, 14)
    }

    func test_helveticaMetrics() throws {
        let f = try XCTUnwrap(Standard14.find("Helvetica"))
        XCTAssertEqual(f.widthOf("space"), 278)
        XCTAssertEqual(f.widthOf("A"), 667)
        XCTAssertEqual(f.ascent, 718)
        XCTAssertEqual(f.descent, -207)
        XCTAssertEqual(f.bBox, FontBox(left: -166, bottom: -225, right: 1000, top: 931))
        XCTAssertNil(f.widthOf("a1"))
    }

    func test_timesAndCourier() throws {
        XCTAssertEqual(try XCTUnwrap(Standard14.find("Times-Roman")).widthOf("A"), 722)
        XCTAssertEqual(try XCTUnwrap(Standard14.find("Times-Bold")).widthOf("A"), 722)
        let courier = try XCTUnwrap(Standard14.find("Courier"))
        XCTAssertTrue(courier.isFixedPitch)
        for g in ["A", "i", "W", "space"] {
            XCTAssertEqual(courier.widthOf(g), 600, g)
        }
    }

    func test_symbolAndZapfDingbatsUseTheirOwnNames() throws {
        let symbol = try XCTUnwrap(Standard14.find("Symbol"))
        XCTAssertEqual(symbol.widthOf("alpha"), 631)
        XCTAssertTrue(symbol.isSymbolic)
        XCTAssertEqual(symbol.ascent, 1010)
        XCTAssertEqual(symbol.builtInEncoding, PdfEncodings.symbol)
        let zapf = try XCTUnwrap(Standard14.find("ZapfDingbats"))
        XCTAssertEqual(zapf.widthOf("a1"), 974)
        XCTAssertEqual(zapf.builtInEncoding, PdfEncodings.zapfDingbats)
        XCTAssertEqual(try XCTUnwrap(Standard14.find("Helvetica")).builtInEncoding, PdfEncodings.standard)
    }

    func test_aliases() {
        let cases = [
            ("Arial", "Helvetica"), ("ArialMT", "Helvetica"), ("Arial,Bold", "Helvetica-Bold"),
            ("Arial-BoldMT", "Helvetica-Bold"), ("Arial-ItalicMT", "Helvetica-Oblique"),
            ("Arial-BoldItalicMT", "Helvetica-BoldOblique"), ("Helvetica-Oblique", "Helvetica-Oblique"),
            ("TimesNewRoman", "Times-Roman"), ("TimesNewRomanPSMT", "Times-Roman"),
            ("TimesNewRomanPS-BoldMT", "Times-Bold"), ("Times New Roman,Italic", "Times-Italic"),
            ("TimesNewRomanPS-BoldItalicMT", "Times-BoldItalic"), ("Times-Roman", "Times-Roman"),
            ("CourierNew", "Courier"), ("CourierNewPS-BoldMT", "Courier-Bold"),
            ("Courier New,BoldItalic", "Courier-BoldOblique"), ("SymbolMT", "Symbol"),
            ("ZapfDingbats", "ZapfDingbats"), ("ABCDEF+Arial", "Helvetica"), ("arial", "Helvetica"),
        ]
        for (alias, name) in cases {
            XCTAssertEqual(Standard14.find(alias)?.name, name, alias)
        }
    }

    func test_otherFontsAreNotStandard() {
        for name in ["", "Arial Narrow", "Arial Black", "Calibri", "Symbolic", "Times-Bogus"] {
            XCTAssertNil(Standard14.find(name), name)
        }
    }

    func test_flagsFollowTheDescriptorBits() throws {
        XCTAssertEqual(try XCTUnwrap(Standard14.find("Courier")).flags, 1 | 32)
        XCTAssertEqual(try XCTUnwrap(Standard14.find("Times-Italic")).flags, 2 | 32 | 64)
        XCTAssertEqual(try XCTUnwrap(Standard14.find("Symbol")).flags, 4)
        XCTAssertNotEqual(try XCTUnwrap(Standard14.find("Helvetica-Bold")).flags & (1 << 18), 0)
    }

    func test_everyGlyphOfStandardEncodingHasAWidth() {
        for f in Standard14.all where !f.isSymbolic {
            for case let name? in PdfEncodings.standard {
                XCTAssertNotNil(f.widthOf(name), "\(f.name) \(name)")
            }
        }
    }
}
