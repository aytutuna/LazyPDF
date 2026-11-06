import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfASubsetTests.cs: the same cases. The program is the Arial of FixtureFonts.swift.

final class PdfASubsetTests: XCTestCase {
    private func subset(_ level: PdfALevel, _ edit: ((PdfDocument, PdfDictionary) throws -> Void)? = nil) throws -> [UInt8] {
        try StandardsKit.edited(PdfAFontTests.composite(level: level)) { d in
            let descriptor = try XCTUnwrap(d.get(11) as? PdfDictionary)
            descriptor["FontName"] = PdfName("ABCDEF+Arial")
            try edit?(d, descriptor)
        }
    }

    private func bits(_ glyphs: [Int]) -> PdfStream {
        var bits = [UInt8](repeating: 0, count: 8192)
        for g in glyphs { bits[g >> 3] |= UInt8(0x80 >> (g & 7)) }
        return PdfStream(PdfDictionary(), data: bits)
    }

    func test_part1AsksForACidSetInASubset() throws {
        StandardsKit.assertHas(try StandardsKit.check(try subset(.a1b), .a1b).issues) { $0.clause == "6.3.5" && $0.message.contains("no /CIDSet") }
        StandardsKit.assertLacks(try StandardsKit.clauses(try subset(.a2b)), "6.2.11.4.2")
        StandardsKit.assertLacks(try StandardsKit.clauses(PdfAFontTests.composite(level: .a1b), .a1b), "6.3.5")
    }

    func test_aCidSetThatListsOnlyTheShownGlyphsOfALargerProgramIsReported() throws {
        let tt = try XCTUnwrap(TrueTypeFont.tryParse(FixtureFonts.arial))
        let shown = [tt.glyphForCodePoint(0x48), tt.glyphForCodePoint(0x69)]
        let only = try subset(.a2b) { d, descriptor in descriptor["CIDSet"] = try d.add(self.bits(shown)) }
        StandardsKit.assertHas(try StandardsKit.check(only).issues) { $0.clause == "6.2.11.4.2" && $0.message.contains("font program") }
        StandardsKit.assertContains(try StandardsKit.clauses(try subset(.a1b) { d, descriptor in descriptor["CIDSet"] = try d.add(self.bits(shown)) }, .a1b), "6.3.5")

        let every = Array(0..<tt.glyphCount)
        let all = try subset(.a2b) { d, descriptor in descriptor["CIDSet"] = try d.add(self.bits(every)) }
        try StandardsKit.assertClean(all)
        try StandardsKit.assertClean(try subset(.a1b) { d, descriptor in descriptor["CIDSet"] = try d.add(self.bits(every)) }, .a1b)
    }

    func test_anOpenTypeFontFileCameWithPdf16() throws {
        let file = try StandardsKit.edited(PdfAFontTests.composite(level: .a1b)) { d in
            let descriptor = try XCTUnwrap(d.get(11) as? PdfDictionary)
            let program = try XCTUnwrap(d.get(10) as? PdfStream)
            program.dictionary["Subtype"] = PdfName("OpenType")
            descriptor["FontFile3"] = descriptor["FontFile2"]
            descriptor.remove("FontFile2")
        }
        StandardsKit.assertHas(try StandardsKit.check(file, .a1b).issues) { $0.clause == "6.3.4" && $0.message.contains("/Subtype") }
        StandardsKit.assertNone(try StandardsKit.check(file, .a2b).issues) { $0.message.contains("/Subtype") }
    }

    func test_aFontThatShowsNothingIsNotHeldToTheFontRules() throws {
        let listed = StandardsKit.compliant(resources: "/Font <</F1 9 0 R>>", extra: { pdf in pdf.obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>") })
        try StandardsKit.assertClean(listed)
        let form = StandardsKit.compliant(catalog: "/AcroForm << /Fields [] /DR << /Font << /Helv 9 0 R >> >> >>",
                                          extra: { pdf in pdf.obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>") })
        try StandardsKit.assertClean(form)
    }

    func test_textInRenderModeThreeNeedsNoEmbeddedFontFromPart2() throws {
        let file = StandardsKit.compliant(content: "BT /F1 12 Tf 3 Tr 20 20 Td (Hi) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        })
        try StandardsKit.assertClean(file)
        StandardsKit.assertContains(try StandardsKit.clauses(file, .a1b), "6.3.4")
        let drawn = StandardsKit.compliant(content: "BT /F1 12 Tf 0 Tr 20 20 Td (Hi) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        })
        StandardsKit.assertContains(try StandardsKit.clauses(drawn), "6.2.11.4.1")
    }

    private func type1CPage(_ name: String, _ charSet: String, _ level: PdfALevel) -> [UInt8] {
        let program = CffBuilder.nameKeyed()
        return StandardsKit.compliant(level, content: "BT /F1 12 Tf 20 20 Td (A) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /\(name) /FirstChar 65 /LastChar 65 /Widths [500] /FontDescriptor 11 0 R /Encoding /WinAnsiEncoding>>")
            pdf.stream(10, "/Subtype /Type1C", program)
            pdf.obj(11, "<</Type /FontDescriptor /FontName /\(name) /Flags 32 /FontBBox [0 0 200 200] /ItalicAngle 0 /Ascent 200 /Descent 0 /CapHeight 200 /StemV 80 /FontFile3 10 0 R \(charSet)>>")
        })
    }

    func test_aCharSetMustNameEveryGlyphOfTheProgram() throws {
        StandardsKit.assertHas(try StandardsKit.check(type1CPage("ABCDEF+Test", "/CharSet (/A)", .a2b)).issues) { $0.clause == "6.2.11.4.2" && $0.message == PdfAText.charSetIncomplete }
        StandardsKit.assertHas(try StandardsKit.check(type1CPage("ABCDEF+Test", "/CharSet (/A)", .a1b), .a1b).issues) { $0.clause == "6.3.5" && $0.message == PdfAText.charSetIncomplete }
        StandardsKit.assertLacks(try StandardsKit.clauses(type1CPage("ABCDEF+Test", "/CharSet (/A/B/custom)", .a2b)), "6.2.11.4.2")
        StandardsKit.assertLacks(try StandardsKit.clauses(type1CPage("ABCDEF+Test", "/CharSet (/A/B/custom)", .a1b), .a1b), "6.3.5")
    }

    func test_part1AsksForACharSetInASubsetAndLaterPartsDoNot() throws {
        StandardsKit.assertHas(try StandardsKit.check(type1CPage("ABCDEF+Test", "", .a1b), .a1b).issues) { $0.clause == "6.3.5" && $0.message == PdfAText.charSetMissing }
        StandardsKit.assertLacks(try StandardsKit.clauses(type1CPage("ABCDEF+Test", "", .a2b)), "6.2.11.4.2")
    }

    func test_part1HoldsOnlyASubsetToItsSets() throws {
        StandardsKit.assertLacks(try StandardsKit.clauses(type1CPage("Test", "", .a1b), .a1b), "6.3.5")
        StandardsKit.assertLacks(try StandardsKit.clauses(type1CPage("Test", "/CharSet (/A)", .a1b), .a1b), "6.3.5")
        StandardsKit.assertContains(try StandardsKit.clauses(type1CPage("Test", "/CharSet (/A)", .a2b)), "6.2.11.4.2")
    }
}
