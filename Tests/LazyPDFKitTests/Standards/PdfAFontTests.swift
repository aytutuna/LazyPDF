import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAFontTests.cs: the same cases. The program is the Arial of FixtureFonts.swift.

final class PdfAFontTests: XCTestCase {
    private static let show = "BT /F1 12 Tf 20 20 Td "

    private static func descriptor(_ flags: String = "32", _ extra: String = "") -> String {
        "<</Type /FontDescriptor /FontName /Arial /Flags \(flags) /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 10 0 R \(extra)>>"
    }

    /// Arial as a simple TrueType font showing "Hi": H is 72 and i is 105.
    static func simple(_ fontEntries: String = "/Encoding /WinAnsiEncoding", flags: String = "32", hWidth: Int = 722, level: PdfALevel = .a2b) -> [UInt8] {
        let program = FixtureFonts.arial
        let widths = (72..<106).map { String($0 == 72 ? hWidth : $0 == 105 ? 222 : 0) }.joined(separator: " ")
        return StandardsKit.compliant(level, content: show + "(Hi) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, "<</Type /Font /Subtype /TrueType /BaseFont /Arial /FirstChar 72 /LastChar 105 /Widths [\(widths)] /FontDescriptor 11 0 R \(fontEntries)>>")
            pdf.stream(10, "/Length1 \(program.count)", program)
            pdf.obj(11, descriptor(flags))
        })
    }

    /// Arial as a Type0 font over Identity-H showing "Hi" by glyph index.
    static func composite(_ cidFontEntries: String = "/CIDToGIDMap /Identity", descriptorExtra: String = "", type0Entries: String = "", level: PdfALevel = .a2b, hWidth: Int = 722) -> [UInt8] {
        let program = FixtureFonts.arial
        let tt = TrueTypeFont.tryParse(program)
        let h = tt?.glyphForCodePoint(0x48) ?? 0, i = tt?.glyphForCodePoint(0x69) ?? 0
        let codes = "<" + String(format: "%04X", UInt32(h)) + String(format: "%04X", UInt32(i)) + ">"
        return StandardsKit.compliant(level, content: show + codes + " Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, "<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /Identity-H /DescendantFonts [12 0 R] \(type0Entries)>>")
            pdf.stream(10, "/Length1 \(program.count)", program)
            pdf.obj(11, descriptor("32", descriptorExtra))
            pdf.obj(12, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 11 0 R /DW 1000 /W [\(h) [\(hWidth)] \(i) [222]] \(cidFontEntries)>>")
        })
    }

    private func dictionary(_ document: PdfDocument, _ number: Int) throws -> PdfDictionary {
        try XCTUnwrap(document.get(number) as? PdfDictionary)
    }

    func test_aFontThatIsNotEmbeddedIsReported() throws {
        let file = StandardsKit.compliant(content: PdfAFontTests.show + "(Hi) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        })
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.clause == "6.2.11.4.1" && $0.where == "Font Helvetica" }
        StandardsKit.assertContains(try StandardsKit.clauses(file, .a1b), "6.3.4")
    }

    func test_anEmbeddedTrueTypeFontPasses() throws {
        try StandardsKit.assertClean(PdfAFontTests.simple())
        try StandardsKit.assertClean(PdfAFontTests.composite())
    }

    func test_widthsThatDisagreeWithTheProgramAreReported() throws {
        StandardsKit.assertHas(try StandardsKit.check(PdfAFontTests.simple(hWidth: 600)).issues) { $0.clause == "6.2.11.5" && $0.message.contains("72") }
        StandardsKit.assertContains(try StandardsKit.clauses(PdfAFontTests.simple(hWidth: 600, level: .a1b), .a1b), "6.3.6")
        StandardsKit.assertContains(try StandardsKit.clauses(PdfAFontTests.composite(hWidth: 500)), "6.2.11.5")
        StandardsKit.assertLacks(try StandardsKit.clauses(PdfAFontTests.simple(hWidth: 723)), "6.2.11.5")
    }

    func test_aSimpleFontWithoutWidthsIsReported() throws {
        let file = try StandardsKit.edited(PdfAFontTests.simple()) { d in
            let font = try self.dictionary(d, 9)
            font.remove("Widths")
            font.remove("FirstChar")
        }
        StandardsKit.assertContains(try StandardsKit.clauses(file), "6.2.11.5")
    }

    func test_trueTypeEncodingRulesDependOnTheSymbolicFlag() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(PdfAFontTests.simple("/Encoding /WinAnsiEncoding", flags: "4")), "6.2.11.6")
        StandardsKit.assertContains(try StandardsKit.clauses(PdfAFontTests.simple("")), "6.2.11.6")
        StandardsKit.assertContains(try StandardsKit.clauses(PdfAFontTests.simple("/Encoding /StandardEncoding")), "6.2.11.6")
        StandardsKit.assertContains(try StandardsKit.clauses(PdfAFontTests.simple("/Encoding /StandardEncoding", level: .a1b), .a1b), "6.3.7")
        StandardsKit.assertLacks(try StandardsKit.clauses(PdfAFontTests.simple("/Encoding /MacRomanEncoding")), "6.2.11.6")
        try StandardsKit.assertClean(PdfAFontTests.simple("", flags: "4"))
    }

    func test_aCidSetThatLeavesOutAGlyphShownIsReported() throws {
        let tt = try XCTUnwrap(TrueTypeFont.tryParse(FixtureFonts.arial))
        let empty = try StandardsKit.edited(PdfAFontTests.composite()) { d in
            let descriptor = try self.dictionary(d, 11)
            descriptor["CIDSet"] = try d.add(PdfStream(PdfDictionary(), data: [UInt8](repeating: 0, count: 16)))
        }
        StandardsKit.assertContains(try StandardsKit.clauses(empty), "6.2.11.4.2")
        StandardsKit.assertLacks(try StandardsKit.clauses(empty, .a1b), "6.3.5")
        let subset = try StandardsKit.edited(empty) { d in try self.dictionary(d, 11)["FontName"] = PdfName("ABCDEF+Arial") }
        StandardsKit.assertContains(try StandardsKit.clauses(subset, .a1b), "6.3.5")

        let complete = try StandardsKit.edited(PdfAFontTests.composite()) { d in
            let descriptor = try self.dictionary(d, 11)
            var bits = [UInt8](repeating: 0, count: (tt.glyphCount + 7) / 8)
            for g in 0..<tt.glyphCount { bits[g >> 3] |= UInt8(0x80 >> (g & 7)) }
            descriptor["CIDSet"] = try d.add(PdfStream(PdfDictionary(), data: bits))
        }
        StandardsKit.assertLacks(try StandardsKit.clauses(complete), "6.2.11.4.2")
    }

    func test_aCompositeFontNeedsAKnownCMapAndAnIdentityGlyphMap() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(PdfAFontTests.composite("")), "6.2.11.3.2")
        let unknown = try StandardsKit.edited(PdfAFontTests.composite()) { d in try self.dictionary(d, 9)["Encoding"] = PdfName("Invented-H") }
        XCTAssertTrue(try StandardsKit.clauses(unknown).joined(separator: " ").contains("6.2.11.3"))
        let noInfo = try StandardsKit.edited(PdfAFontTests.composite()) { d in try self.dictionary(d, 12).remove("CIDSystemInfo") }
        XCTAssertTrue(try StandardsKit.clauses(noInfo).joined(separator: " ").contains("6.2.11.3"))
    }

    func test_levelUNeedsAWayToUnicode() throws {
        let without = PdfAFontTests.composite(level: .a2u)
        StandardsKit.assertContains(try StandardsKit.clauses(without, .a2u), "6.2.11.7.2")
        StandardsKit.assertLacks(try StandardsKit.clauses(without, .a2b), "6.2.11.7.2")

        let with = try StandardsKit.edited(without) { d in
            let data = try ToUnicodeCMap.write([(key: 1, value: "H")])
            try self.dictionary(d, 9)["ToUnicode"] = try d.add(PdfStream(PdfDictionary(), data: data))
        }
        StandardsKit.assertLacks(try StandardsKit.clauses(with, .a2u), "6.2.11.7.2")
    }

    func test_aSimpleLatinFontReachesUnicodeThroughItsGlyphNames() throws {
        StandardsKit.assertLacks(try StandardsKit.clauses(PdfAFontTests.simple(level: .a2u), .a2u), "6.2.11.7.2")
        StandardsKit.assertContains(try StandardsKit.clauses(PdfAFontTests.simple("/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [72 /g12] >>", level: .a2u), .a2u), "6.2.11.7.2")
    }
}
