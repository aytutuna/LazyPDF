import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAFontConversionTests.cs: the same cases. The PigText lines (the text read by
// PdfPig) have no twin. The fonts the converter embeds are those of FixtureFonts.swift; SystemFonts.RequireArial and the
// check that symbol.ttf is installed are not needed.

final class PdfAFontConversionTests: XCTestCase {
    private func convert(_ file: [UInt8], _ level: PdfALevel = .a2b, _ fonts: FontSource? = SystemFonts()) throws -> PdfAConversion {
        try PdfAConverter(fonts).convert(file, level, StandardsKit.date)
    }

    private func clean(_ result: PdfAConversion) throws -> [UInt8] {
        XCTAssertNil(result.refusal)
        XCTAssertTrue(result.remaining.isEmpty, result.remaining.map { "\($0.clause) \($0.where): \($0.message)" }.joined(separator: "\n"))
        return try XCTUnwrap(result.bytes)
    }

    private func page(_ fontObject: String, _ content: String, _ extra: ((TestPdf) -> Void)? = nil) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.stream(4, "", content)
        pdf.obj(5, fontObject)
        extra?(pdf)
        return pdf.finish("/Root 1 0 R")
    }

    private func fontOf(_ document: PdfDocument) throws -> PdfFont {
        let fonts = try XCTUnwrap(document.dict(document.pages[0].resources, "Font"))
        return PdfFont.get(document, try XCTUnwrap(document.resolve(fonts["F1"]) as? PdfDictionary))
    }

    private func glyph(_ codePoint: Int) throws -> Int {
        try XCTUnwrap(TrueTypeFont.tryParse(FixtureFonts.arial)).glyphForCodePoint(codePoint)
    }

    func test_theStandardFontsAreReplacedByTheirMetricTwins() throws {
        for (baseFont, expectedInName) in [("Times-BoldItalic", "Times"), ("Courier", "Cour"), ("Helvetica-Oblique", "Arial")] {
            let file = page("<</Type /Font /Subtype /Type1 /BaseFont /\(baseFont) /Encoding /WinAnsiEncoding>>", "BT /F1 12 Tf 20 100 Td (Quick fox) Tj ET")
            let bytes = try clean(try convert(file))
            let document = try PdfDocument.open(bytes)
            let font = try fontOf(document)
            XCTAssertTrue(font.isEmbedded, baseFont)
            XCTAssertTrue(font.baseFont.lowercased().contains(expectedInName.lowercased()), "\(baseFont): \(font.baseFont)")
        }
    }

    func test_theWidthsOfTheOldFontSurviveBecauseTheTwinHasTheSameMetrics() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>", "BT /F1 12 Tf 20 100 Td (Wide WWW) Tj ET")
        let before = try PdfDocument.open(file)
        let expected = try fontOf(before).decode(Array("Wide WWW".utf8)).reduce(0.0) { $0 + $1.width }
        let after = try PdfDocument.open(try clean(try convert(file)))
        XCTAssertEqual(try fontOf(after).decode(Array("Wide WWW".utf8)).reduce(0.0) { $0 + $1.width }, expected, accuracy: 0.5)
    }

    func test_aLatinFontNotInTheStandardSetIsReplacedByTheSourcesClosestFamily() throws {
        let file = page("<</Type /Font /Subtype /TrueType /BaseFont /Calibri-Bold /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 33 /Widths [226 326] /FontDescriptor 6 0 R>>",
                        "BT /F1 12 Tf 20 100 Td (Hi!) Tj ET", { pdf in
            pdf.obj(6, "<</Type /FontDescriptor /FontName /Calibri-Bold /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 750 /Descent -250 /CapHeight 640 /StemV 100>>")
        })
        let bytes = try clean(try convert(file))
        let document = try PdfDocument.open(bytes)
        XCTAssertTrue(try fontOf(document).isEmbedded)
    }

    func test_theSymbolFontIsReplacedByTheSourcesSymbolFont() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Symbol>>", "BT /F1 12 Tf 20 100 Td (abg) Tj ET")
        let bytes = try clean(try convert(file))
        let document = try PdfDocument.open(bytes)
        XCTAssertEqual(try fontOf(document).toText(Array("abg".utf8)), "\u{3B1}\u{3B2}\u{3B3}")
    }

    func test_aCompositeFontNotEmbeddedKeepsItsCodesAndGetsGlyphsFromTheSource() throws {
        let toUnicode = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <0000> <FFFF> endcodespacerange "
            + "2 beginbfchar <0001> <0048> <0002> <0069> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end"
        let file = page("<</Type /Font /Subtype /Type0 /BaseFont /ArialMT /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 8 0 R>>", "BT /F1 12 Tf 20 100 Td <00010002> Tj ET", { pdf in
            pdf.obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /ArialMT /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 7 0 R /DW 600>>")
            pdf.obj(7, "<</Type /FontDescriptor /FontName /ArialMT /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80>>")
            pdf.stream(8, "", toUnicode)
        })
        let bytes = try clean(try convert(file))
        let document = try PdfDocument.open(bytes)
        XCTAssertTrue(try fontOf(document).isEmbedded)
        XCTAssertEqual(try fontOf(document).toText([0, 1, 0, 2]), "Hi")
    }

    func test_withoutAFontSourceTheFontStaysAndIsReported() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>", "BT /F1 12 Tf 20 100 Td (Hi) Tj ET")
        let result = try PdfAConverter().convert(file, .a2b, StandardsKit.date)
        XCTAssertNotNil(result.bytes)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.4.1" && $0.where == "Font Helvetica" }
    }

    func test_wrongWidthsOfAnEmbeddedFontAreSetFromItsProgram() throws {
        let simple = PdfAFontTests.simple(hWidth: 600)
        let result = try convert(simple)
        let bytes = try clean(result)
        XCTAssertTrue(result.changes.contains { $0.contains("fonts were corrected") })
        let document = try PdfDocument.open(bytes)
        XCTAssertEqual(try fontOf(document).decode(Array("H".utf8))[0].width, 722, accuracy: 0.5)

        let cid = try PdfDocument.open(try clean(try convert(PdfAFontTests.composite(hWidth: 500))))
        let h = try glyph(0x48)
        XCTAssertEqual(try fontOf(cid).decode([UInt8(h >> 8), UInt8(h & 0xFF)])[0].width, 722, accuracy: 0.5)
    }

    func test_aWrongCidSetAndASymbolicEncodingAreCorrected() throws {
        let withSet = try StandardsKit.edited(PdfAFontTests.composite()) { d in
            let descriptor = try XCTUnwrap(d.get(11) as? PdfDictionary)
            descriptor["CIDSet"] = try d.add(PdfStream(PdfDictionary(), data: [UInt8](repeating: 0, count: 16)))
        }
        StandardsKit.assertContains(try StandardsKit.clauses(withSet), "6.2.11.4.2")
        _ = try clean(try convert(withSet))

        _ = try clean(try convert(PdfAFontTests.simple("/Encoding /WinAnsiEncoding", flags: "4")))
        _ = try clean(try convert(PdfAFontTests.simple("")))
        _ = try clean(try convert(PdfAFontTests.composite("")))
    }

    func test_anEmbeddedFontMissingItsToUnicodeGetsOneAtLevelU() throws {
        let bytes = try clean(try convert(PdfAFontTests.composite(level: .a2u), .a2u))
        let document = try PdfDocument.open(bytes)
        let font = try fontOf(document)
        XCTAssertTrue(font.hasToUnicode)
        let h = try glyph(0x48)
        XCTAssertEqual(font.toText([UInt8(h >> 8), UInt8(h & 0xFF)]), "H")
    }
}
