import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAFontFixTests.cs: the same cases. The programs are the Arial and Symbol of
// FixtureFonts.swift, which have the cmaps, names and advances the cases look at; the check that symbol.ttf is installed is
// not needed.

final class PdfAFontFixTests: XCTestCase {
    private func convert(_ file: [UInt8], _ level: PdfALevel = .a2b) throws -> PdfAConversion {
        try PdfAConverter(SystemFonts()).convert(file, level, StandardsKit.date)
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

    private func arialPage(_ fontEntries: String, _ flags: String, _ content: String, _ level: PdfALevel = .a2b, _ more: ((TestPdf) -> Void)? = nil) -> [UInt8] {
        fontPage("arial.ttf", fontEntries, flags, content, level, more)
    }

    private func fontPage(_ file: String, _ fontEntries: String, _ flags: String, _ content: String, _ level: PdfALevel, _ more: ((TestPdf) -> Void)? = nil,
                          patch: (([UInt8]) -> [UInt8])? = nil) -> [UInt8] {
        var program = file == "symbol.ttf" ? FixtureFonts.symbol() : FixtureFonts.arial
        if let patch { program = patch(program) }
        let font = program
        return StandardsKit.compliant(level, content: "BT /F1 12 Tf 20 20 Td " + content + " ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, "<</Type /Font /Subtype /TrueType /BaseFont /Arial /FirstChar 39 /LastChar 39 /Widths [191] /FontDescriptor 11 0 R \(fontEntries)>>")
            pdf.stream(10, "/Length1 \(font.count)", font)
            pdf.obj(11, "<</Type /FontDescriptor /FontName /ABCDEF+Arial /Flags \(flags) /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 10 0 R>>")
            more?(pdf)
        })
    }

    private func descriptor(_ document: PdfDocument) throws -> PdfDictionary {
        let font = try fontOf(document).dictionary
        var holder = font
        if let kids = document.array(font, "DescendantFonts"), let first = kids.items.first, let cid = document.resolve(first) as? PdfDictionary { holder = cid }
        return try XCTUnwrap(document.dict(holder, "FontDescriptor"))
    }

    func test_aDingbatsFontTheSourceCannotDrawStaysUnembeddedAndIsReported() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats>>", "BT /F1 12 Tf 20 100 Td (4) Tj ET")
        let result = try convert(file)
        XCTAssertNotNil(result.bytes)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.4.1" && $0.where == "Font ZapfDingbats" }
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertFalse(try fontOf(document).isEmbedded)
    }

    func test_textOfSeveralCharactersIsNotDrawnWithTheGlyphOfTheFirst() throws {
        let toUnicode = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <00> <FF> endcodespacerange "
            + "1 beginbfchar <41> <00660069> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end"
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R>>", "BT /F1 12 Tf 20 100 Td (AB) Tj ET", { pdf in
            pdf.stream(6, "", toUnicode)
        })
        let result = try convert(file)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.4.1" }
    }

    func test_aCompositeCodeWithoutTextKeepsTheFontUnembedded() throws {
        let toUnicode = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <0000> <FFFF> endcodespacerange "
            + "2 beginbfchar <0001> <0048> <0002> <0069> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end"
        let file = page("<</Type /Font /Subtype /Type0 /BaseFont /ArialMT /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 8 0 R>>", "BT /F1 12 Tf 20 100 Td <00010003> Tj ET", { pdf in
            pdf.obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /ArialMT /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 7 0 R /DW 600>>")
            pdf.obj(7, "<</Type /FontDescriptor /FontName /ArialMT /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80>>")
            pdf.stream(8, "", toUnicode)
        })
        StandardsKit.assertHas(try convert(file).remaining) { $0.clause == "6.2.11.4.1" }
    }

    func test_aSymbolFontStandInGivesEveryCodeAGlyph() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Symbol>>", "BT /F1 12 Tf 20 100 Td (abg) Tj ET")
        let document = try PdfDocument.open(try clean(try convert(file)))
        for character in try fontOf(document).decode(Array("abg".utf8)) { XCTAssertNotEqual(character.cid, 0) }
    }

    func test_aNewSubsetGetsACidSetForPartOne() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>", "BT /F1 12 Tf 20 100 Td (Hi) Tj ET")
        let document = try PdfDocument.open(try XCTUnwrap(try convert(file, .a1b).bytes))
        let set = try XCTUnwrap(document.stream(try descriptor(document), "CIDSet"))
        let bits = try document.data(set, 1 << 20)
        let cid = try fontOf(document).decode(Array("H".utf8))[0].cid
        XCTAssertNotEqual(Int(bits[cid >> 3]) & (0x80 >> (cid & 7)), 0)
    }

    private func glyph(_ codePoint: Int) throws -> Int {
        try XCTUnwrap(TrueTypeFont.tryParse(FixtureFonts.arial)).glyphForCodePoint(codePoint)
    }

    func test_aMissingOrShortCidSetOfASubsetIsWrittenAgainForPartOne() throws {
        let subset = try StandardsKit.edited(PdfAFontTests.composite(level: .a1b)) { d in
            let descriptor = try XCTUnwrap(d.get(11) as? PdfDictionary)
            descriptor["FontName"] = PdfName("ABCDEF+Arial")
            descriptor["CIDSet"] = try d.add(PdfStream(PdfDictionary(), data: [UInt8](repeating: 0, count: 4)))
        }
        let document = try PdfDocument.open(try XCTUnwrap(try convert(subset, .a1b).bytes))
        let bits = try document.data(try XCTUnwrap(document.stream(try descriptor(document), "CIDSet")), 1 << 20)
        let h = try glyph(0x48)
        XCTAssertNotEqual(Int(bits[h >> 3]) & (0x80 >> (h & 7)), 0)

        let without = try StandardsKit.edited(PdfAFontTests.composite(level: .a1b)) { d in
            try XCTUnwrap(d.get(11) as? PdfDictionary)["FontName"] = PdfName("ABCDEF+Arial")
        }
        let written = try PdfDocument.open(try XCTUnwrap(try convert(without, .a1b).bytes))
        XCTAssertNotNil(written.stream(try descriptor(written), "CIDSet"))
    }

    func test_aCodeWithoutTextGetsTheMapOfTheOthersAndIsReportedAtLevelU() throws {
        let proc = "10 0 0 0 10 10 d1 0 0 10 10 re f"
        let file = page("<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.1 0 0 0.1 0 0] /CharProcs <</A 6 0 R /g1 7 0 R>> "
            + "/Encoding <</Type /Encoding /Differences [65 /A /g1]>> /FirstChar 65 /LastChar 66 /Widths [10 10]>>", "BT /F1 12 Tf 20 100 Td (AB) Tj ET", { pdf in
            pdf.stream(6, "", proc)
            pdf.stream(7, "", proc)
        })
        let result = try convert(file, .a2u)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.7.2" }
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertEqual(try fontOf(document).decode(Array("A".utf8))[0].unicode, "A")
    }

    func test_aTrueTypeFontWithStandardEncodingKeepsItsGlyphsUnderWinAnsi() throws {
        let file = arialPage("/Encoding /StandardEncoding", "32", "(') Tj")
        let before = try PdfDocument.open(file)
        XCTAssertEqual(try fontOf(before).decode(Array("'".utf8))[0].unicode, "\u{2019}")
        let after = try PdfDocument.open(try clean(try convert(file)))
        XCTAssertEqual(try fontOf(after).decode(Array("'".utf8))[0].unicode, "\u{2019}")
    }

    func test_aSymbolicTrueTypeFontWhoseEncodingChangesGlyphsKeepsThemUnderNames() throws {
        let file = arialPage("/Encoding << /Type /Encoding /Differences [39 /quoteright] >>", "4", "(') Tj")
        let before = try PdfDocument.open(file)
        XCTAssertEqual(try fontOf(before).decode(Array("'".utf8))[0].unicode, "\u{2019}")
        let after = try PdfDocument.open(try clean(try convert(file)))
        XCTAssertEqual(try fontOf(after).decode(Array("'".utf8))[0].unicode, "\u{2019}")
    }

    private func cidSetOf(_ document: PdfDocument) throws -> [UInt8] {
        try document.data(try XCTUnwrap(document.stream(try descriptor(document), "CIDSet")), 1 << 20)
    }

    private func listed(_ bits: [UInt8], _ cid: Int) -> Bool { (cid >> 3) < bits.count && (Int(bits[cid >> 3]) & (0x80 >> (cid & 7))) != 0 }

    private func installed() throws -> TrueTypeFont { try XCTUnwrap(TrueTypeFont.tryParse(FixtureFonts.arial)) }

    private func oneToUnicode(_ text: String) -> String {
        "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <00> <FF> endcodespacerange "
            + "1 beginbfchar <41> <\(text)> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end"
    }

    func test_aNewSubsetNamesEveryGlyphOfItsProgramInTheCidSet() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>", "BT /F1 12 Tf 20 100 Td (Hi) Tj ET")
        let document = try PdfDocument.open(try clean(try convert(file, .a1b)))
        let programStream = try XCTUnwrap(document.resolve(try descriptor(document)["FontFile2"]) as? PdfStream)
        let program = try XCTUnwrap(TrueTypeFont.tryParse(try document.data(programStream, 1 << 26)))
        let bits = try cidSetOf(document)
        let drawn = (1..<program.glyphCount).filter { program.glyphData($0).length > 0 }
        XCTAssertTrue(drawn.count > 2)
        for g in drawn { XCTAssertTrue(listed(bits, g), "glyph \(g)") }
    }

    func test_aCidSetOfOnlyTheShownGlyphsOfALargerProgramIsRebuiltAtPart2() throws {
        let arial = try installed()
        let subset = try StandardsKit.edited(PdfAFontTests.composite()) { d in
            let descriptor = try XCTUnwrap(d.get(11) as? PdfDictionary)
            descriptor["FontName"] = PdfName("ABCDEF+Arial")
            var bits = [UInt8](repeating: 0, count: 8192)
            for g in [arial.glyphForCodePoint(0x48), arial.glyphForCodePoint(0x69)] { bits[g >> 3] |= UInt8(0x80 >> (g & 7)) }
            descriptor["CIDSet"] = try d.add(PdfStream(PdfDictionary(), data: bits))
        }
        let document = try PdfDocument.open(try clean(try convert(subset)))
        XCTAssertTrue(listed(try cidSetOf(document), arial.glyphForCodePoint(0x41)))
    }

    func test_aCidSetIsBuiltForAFontWithACidToGidMapStream() throws {
        let arial = try installed()
        let h = arial.glyphForCodePoint(0x48), i = arial.glyphForCodePoint(0x69)
        let subset = try StandardsKit.edited(PdfAFontTests.composite(level: .a1b)) { d in
            try XCTUnwrap(d.get(11) as? PdfDictionary)["FontName"] = PdfName("ABCDEF+Arial")
            var map = [UInt8](repeating: 0, count: (Swift.max(h, i) + 1) * 2)
            for g in [h, i] {
                map[2 * g] = UInt8(g >> 8)
                map[2 * g + 1] = UInt8(g & 0xFF)
            }
            try XCTUnwrap(d.get(12) as? PdfDictionary)["CIDToGIDMap"] = try d.add(PdfStream(PdfDictionary(), data: map))
        }
        let document = try PdfDocument.open(try clean(try convert(subset, .a1b)))
        let bits = try cidSetOf(document)
        XCTAssertTrue(listed(bits, h) && listed(bits, i))
    }

    func test_aToUnicodeThatMapsToNulIsRewrittenFromTheEncoding() throws {
        let file = arialPage("/Encoding /WinAnsiEncoding /ToUnicode 12 0 R", "32", "(A) Tj", .a2u, { pdf in pdf.stream(12, "", self.oneToUnicode("0000")) })
        let before = try PdfDocument.open(file)
        XCTAssertEqual(try fontOf(before).decode(Array("A".utf8))[0].unicode, "\0")
        let after = try PdfDocument.open(try clean(try convert(file, .a2u)))
        XCTAssertEqual(try fontOf(after).decode(Array("A".utf8))[0].unicode, "A")
    }

    func test_aToUnicodeWithAHoleKeepsTheTextItCanTraceAndIsReported() throws {
        let proc = "10 0 0 0 10 10 d1 0 0 10 10 re f"
        let file = page("<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.1 0 0 0.1 0 0] /CharProcs <</A 6 0 R /g1 7 0 R>> "
            + "/Encoding <</Type /Encoding /Differences [65 /A /g1]>> /FirstChar 65 /LastChar 66 /Widths [10 10] /ToUnicode 8 0 R>>", "BT /F1 12 Tf 20 100 Td (AB) Tj ET", { pdf in
            pdf.stream(6, "", proc)
            pdf.stream(7, "", proc)
            pdf.stream(8, "", self.oneToUnicode("0041"))
        })
        let result = try convert(file, .a2u)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.7.2" }
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertEqual(try fontOf(document).decode(Array("A".utf8))[0].unicode, "A")
    }

    func test_aCodeTheEncodingHasNoNameForKeepsItsGlyphUnderWinAnsi() throws {
        let standard = arialPage("/Encoding /StandardEncoding", "32", "<E0> Tj")
        XCTAssertEqual(try fontOf(try PdfDocument.open(standard)).decode([0xE0])[0].unicode, "\u{2021}")
        XCTAssertEqual(try fontOf(try PdfDocument.open(try clean(try convert(standard)))).decode([0xE0])[0].unicode, "\u{2021}")

        let unnamed = arialPage("/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [224 /foo] >>", "32", "<E0> Tj")
        XCTAssertEqual(try fontOf(try PdfDocument.open(unnamed)).decode([0xE0])[0].unicode, "\u{2021}")
        XCTAssertEqual(try fontOf(try PdfDocument.open(try clean(try convert(unnamed)))).decode([0xE0])[0].unicode, "\u{2021}")

        let levelU = arialPage("/Encoding /StandardEncoding", "32", "<80> Tj", .a2u)
        XCTAssertEqual(try fontOf(try PdfDocument.open(levelU)).decode([0x80])[0].unicode, "\u{C4}")
        XCTAssertEqual(try fontOf(try PdfDocument.open(try clean(try convert(levelU, .a2u)))).decode([0x80])[0].unicode, "\u{C4}")
    }

    func test_aSymbolicFontWithoutAUnicodeCmapKeepsItsEncodingAndIsReported() throws {
        let file = fontPage("symbol.ttf", "/Encoding << /Type /Encoding /Differences [65 /B] >>", "4", "(A) Tj", .a2b)
        let result = try convert(file)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.6" }
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertEqual(document.integer(try descriptor(document), "Flags"), 4)
    }

    func test_aSymbolFontStandInDrawsTheGlyphTheEncodingNames() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Symbol /Encoding <</Type /Encoding /Differences [65 /beta]>>>>", "BT /F1 12 Tf 20 100 Td (A) Tj ET")
        let document = try PdfDocument.open(try clean(try convert(file)))
        let symbol = try XCTUnwrap(TrueTypeFont.tryParse(FixtureFonts.symbol()))
        let first = symbol.glyphForCmap(3, 0, 0x62)
        let beta = first > 0 ? first : symbol.glyphForCmap(3, 0, 0xF062)
        let drawn = try fontOf(document).decode(Array("A".utf8))[0]
        XCTAssertEqual(drawn.unicode, "\u{3B2}")
        XCTAssertEqual(Double(symbol.getAdvance(beta)) * 1000.0 / Double(symbol.unitsPerEm), drawn.width, accuracy: 0.5)
    }

    func test_aCodeBelow32TheEncodingNamesKeepsTheFontUnembedded() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [1 /g1]>>>>", "BT /F1 12 Tf 20 100 Td <0141> Tj ET")
        let result = try convert(file, .a2u)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.4.1" }
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertFalse(try fontOf(document).isEmbedded)
    }

    func test_aReplacementTakesTheTextOfABadToUnicodeFromTheEncoding() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R>>", "BT /F1 12 Tf 20 100 Td (A) Tj ET", { pdf in
            pdf.stream(6, "", self.oneToUnicode("0000"))
        })
        let document = try PdfDocument.open(try clean(try convert(file, .a2u)))
        XCTAssertEqual(try fontOf(document).decode(Array("A".utf8))[0].unicode, "A")
    }

    private func type1CPage(_ charSet: String, _ encoding: String, _ level: PdfALevel) -> [UInt8] {
        let program = CffBuilder.nameKeyed()
        return StandardsKit.compliant(level, content: "BT /F1 12 Tf 20 20 Td (A) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /ABCDEF+Test /FirstChar 65 /LastChar 65 /Widths [500] /FontDescriptor 11 0 R \(encoding)>>")
            pdf.stream(10, "/Subtype /Type1C", program)
            pdf.obj(11, "<</Type /FontDescriptor /FontName /ABCDEF+Test /Flags 32 /FontBBox [0 0 200 200] /ItalicAngle 0 /Ascent 200 /Descent 0 /CapHeight 200 /StemV 80 /FontFile3 10 0 R \(charSet)>>")
        })
    }

    private func charSetOf(_ document: PdfDocument) throws -> String {
        let value = try XCTUnwrap(document.resolve(try descriptor(document)["CharSet"]) as? PdfString)
        return Latin1.string(value.bytes)
    }

    func test_aCharSetThatMissesGlyphsIsRebuiltWithoutNotdef() throws {
        let file = type1CPage("/CharSet (/A)", "/Encoding /WinAnsiEncoding", .a2b)
        let document = try PdfDocument.open(try clean(try convert(file)))
        XCTAssertEqual(try charSetOf(document), "/A/B/custom")

        let without = type1CPage("", "/Encoding /WinAnsiEncoding", .a1b)
        let written = try PdfDocument.open(try clean(try convert(without, .a1b)))
        XCTAssertEqual(try charSetOf(written), "/A/B/custom")
    }

    func test_aCharSetNamesAShownGlyphTheProgramLacks() throws {
        let file = type1CPage("/CharSet (/A)", "/Encoding << /Type /Encoding /Differences [65 /foo] >>", .a2b)
        let document = try PdfDocument.open(try clean(try convert(file)))
        XCTAssertTrue(try charSetOf(document).contains("/foo"))
    }

    // Renumbers every cmap subtable but (1,0) so that a reader finds glyphs by name only through MacRoman.
    private func macOnly(_ font: [UInt8]) -> [UInt8] {
        var copy = font
        let tables = Int(copy[4]) << 8 | Int(copy[5])
        for i in 0..<tables {
            let entry = 12 + 16 * i
            if Latin1.string(Array(copy[entry..<(entry + 4)])) != "cmap" { continue }
            let cmap = Int(copy[entry + 8]) << 24 | Int(copy[entry + 9]) << 16 | Int(copy[entry + 10]) << 8 | Int(copy[entry + 11])
            let count = Int(copy[cmap + 2]) << 8 | Int(copy[cmap + 3])
            for k in 0..<count {
                let record = cmap + 4 + 8 * k
                if (Int(copy[record]) << 8 | Int(copy[record + 1])) == 1 && (Int(copy[record + 2]) << 8 | Int(copy[record + 3])) == 0 { continue }
                copy[record] = 0
                copy[record + 1] = 9
            }
        }
        return copy
    }

    // Sets the post table to format 1, which names the first 258 glyphs in the standard Macintosh order.
    private func namedGlyphs(_ font: [UInt8]) -> [UInt8] {
        var copy = font
        let tables = Int(copy[4]) << 8 | Int(copy[5])
        for i in 0..<tables {
            let entry = 12 + 16 * i
            if Latin1.string(Array(copy[entry..<(entry + 4)])) != "post" { continue }
            let post = Int(copy[entry + 8]) << 24 | Int(copy[entry + 9]) << 16 | Int(copy[entry + 10]) << 8 | Int(copy[entry + 11])
            (copy[post], copy[post + 1], copy[post + 2], copy[post + 3]) = (0, 1, 0, 0)
        }
        return copy
    }

    func test_aConvertedFontKeepsItsToUnicodeWhenConvertedAgainToLevelU() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>", "BT /F1 12 Tf 20 100 Td (Hi there) Tj ET")
        let first = try clean(try convert(file))
        XCTAssertEqual(try fontOf(try PdfDocument.open(first)).toText(Array("Hi there".utf8)), "Hi there")
        let document = try PdfDocument.open(try clean(try convert(first, .a2u)))
        XCTAssertTrue(try fontOf(document).hasToUnicode)
        XCTAssertEqual(try fontOf(document).toText(Array("Hi there".utf8)), "Hi there")
    }

    func test_aToUnicodeOfALatinFontWithAHoleLosesItsNulAndTheHoleIsReported() throws {
        let file = arialPage("/Encoding /WinAnsiEncoding /ToUnicode 12 0 R", "32", "<4101> Tj", .a2u, { pdf in pdf.stream(12, "", self.oneToUnicode("0000")) })
        let result = try convert(file, .a2u)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.7.2" }
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertEqual(try fontOf(document).decode([0x41])[0].unicode, "A")
    }

    func test_aCodeWithoutTextInALatinFontWithNoMapIsReportedAtLevelU() throws {
        let file = arialPage("/Encoding /WinAnsiEncoding", "32", "<4101> Tj", .a2u)
        StandardsKit.assertHas(try convert(file, .a2u).remaining) { $0.clause == "6.2.11.7.2" }
        _ = try clean(try convert(arialPage("/Encoding /WinAnsiEncoding", "32", "<41> Tj", .a2u), .a2u))
    }

    private func byteCoded(_ toUnicode: String) throws -> [UInt8] {
        let h = try glyph(0x48), i = try glyph(0x69)
        let program = FixtureFonts.arial
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Byte def /CMapType 1 def 1 begincodespacerange <00> <FF> endcodespacerange "
            + "2 begincidchar <69> \(h) <6A> \(i) endcidchar endcmap CMapName currentdict /CMap defineresource pop end end"
        return StandardsKit.compliant(.a2u, content: "BT /F1 12 Tf 20 20 Td <696A> Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, "<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding 13 0 R /DescendantFonts [12 0 R] /ToUnicode 14 0 R>>")
            pdf.stream(10, "/Length1 \(program.count)", program)
            pdf.obj(11, "<</Type /FontDescriptor /FontName /Arial /Flags 32 /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 10 0 R>>")
            pdf.obj(12, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 11 0 R /DW 1000 /W [\(h) [722] \(i) [222]] /CIDToGIDMap /Identity>>")
            pdf.stream(13, "/Type /CMap /CMapName /Byte /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>", cmap)
            pdf.stream(14, "", toUnicode)
        })
    }

    func test_aCompositeFontUnderAOneByteCMapGetsTheTextItsMapLacks() throws {
        let head = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <00> <FF> endcodespacerange "
        let tail = " endcmap CMapName currentdict /CMap defineresource pop end end"
        for toUnicode in [head + "1 beginbfchar <69> <0000> endbfchar" + tail, head + "1 beginbfchar <69> <0048> endbfchar" + tail] {
            let document = try PdfDocument.open(try clean(try convert(try byteCoded(toUnicode), .a2u)))
            let stream = try XCTUnwrap(document.stream(try fontOf(document).dictionary, "ToUnicode"))
            let written = CMap.parse(try document.data(stream, 1 << 16))
            XCTAssertEqual(written.unicodeOf(0x69, length: 1), "H")
            XCTAssertEqual(written.unicodeOf(0x6A, length: 1), "i")
        }
    }

    func test_aCompositeFontEmbeddedFromTheEncodingGetsAToUnicodeWithoutHoles() throws {
        let toUnicode = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <0000> <FFFF> endcodespacerange "
            + "1 beginbfchar <0022> <0000> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end"
        let file = page("<</Type /Font /Subtype /Type0 /BaseFont /ArialMT /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 8 0 R>>", "BT /F1 12 Tf 20 100 Td <00220023> Tj ET", { pdf in
            pdf.obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /ArialMT /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 2 >> /FontDescriptor 7 0 R /DW 600>>")
            pdf.obj(7, "<</Type /FontDescriptor /FontName /ArialMT /Flags 32 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80>>")
            pdf.stream(8, "", toUnicode)
        })
        let document = try PdfDocument.open(try clean(try convert(file, .a2u)))
        XCTAssertEqual(try fontOf(document).decode([0, 0x22, 0, 0x23]).map { $0.unicode }, ["A", "B"])
    }

    func test_aControlCodeWithoutAGlyphNameKeepsTheFontUnembedded() throws {
        let file = page("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>", "BT /F1 12 Tf 20 100 Td <41094B> Tj ET")
        let result = try convert(file)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.4.1" }
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertFalse(try fontOf(document).isEmbedded)
    }

    func test_aNameThatReachesAnotherGlyphThroughMacRomanIsNotRewrittenWithoutAUnicodeCmap() throws {
        let standard = fontPage("arial.ttf", "/Encoding /StandardEncoding", "32", "(') Tj", .a2b, patch: macOnly)
        let result = try convert(standard)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.6" }
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertEqual(document.name(try fontOf(document).dictionary, "Encoding"), "StandardEncoding")

        let listedFile = fontPage("arial.ttf", "/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [39 /quoteright] >>", "32", "(') Tj", .a2b, patch: macOnly)
        let kept = try convert(listedFile)
        StandardsKit.assertHas(kept.remaining) { $0.clause == "6.2.11.6" && $0.message == PdfAText.trueTypeDifferences }
        let after = try PdfDocument.open(try XCTUnwrap(kept.bytes))
        let encoding = try XCTUnwrap(after.dict(try fontOf(after).dictionary, "Encoding"))
        XCTAssertNotNil(after.array(encoding, "Differences"))
    }

    func test_aSymbolicFontWithoutAUnicodeCmapIsNotMadeNonSymbolic() throws {
        let file = fontPage("symbol.ttf", "/Encoding /WinAnsiEncoding", "4", "<B0> Tj", .a2b)
        let result = try convert(file)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.6" }
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertEqual(document.integer(try descriptor(document), "Flags"), 4)
        XCTAssertEqual(document.name(try fontOf(document).dictionary, "Encoding"), "WinAnsiEncoding")
    }

    func test_aSymbolicFontWhoseNamesReachOtherGlyphsThroughMacRomanKeepsItsEncoding() throws {
        let file = fontPage("arial.ttf", "/Encoding /StandardEncoding", "4", "(') Tj", .a2b, patch: macOnly)
        let result = try convert(file)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.11.6" }
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertEqual(document.name(try fontOf(document).dictionary, "Encoding"), "StandardEncoding")
        XCTAssertEqual(document.integer(try descriptor(document), "Flags"), 4)
    }

    private func differenceNames(_ document: PdfDocument) throws -> [String] {
        guard let encoding = document.dict(try fontOf(document).dictionary, "Encoding") else { return [] }
        let differences = try XCTUnwrap(document.array(encoding, "Differences"))
        return differences.items.compactMap { document.resolve($0) as? PdfName }.map { $0.value }
    }

    func test_aTrueTypeFontWithNoEncodingStartsFromStandardEncoding() throws {
        let none = arialPage("", "32", "(') Tj")
        let document = try PdfDocument.open(try clean(try convert(none)))
        XCTAssertEqual(try fontOf(document).decode(Array("'".utf8))[0].unicode, "\u{2019}")

        let noBase = arialPage("/Encoding << /Type /Encoding /Differences [65 /B] >>", "32", "(`A) Tj")
        let written = try PdfDocument.open(try clean(try convert(noBase)))
        XCTAssertEqual(try fontOf(written).decode(Array("`A".utf8)).map { $0.unicode }, ["\u{2018}", "B"])
    }

    func test_namesOutsideTheGlyphListAreNotLeftInTheDifferences() throws {
        let file = arialPage("/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [65 /a1 66 /A.sc] >>", "32", "(AB) Tj")
        let document = try PdfDocument.open(try clean(try convert(file)))
        for name in try differenceNames(document) { XCTAssertFalse(name == "a1" || name == "A.sc", name) }

        let pinned = arialPage("/Encoding << /Type /Encoding /Differences [65 /uni01F8] >>", "32", "(A) Tj")
        StandardsKit.assertHas(try convert(pinned).remaining) { $0.clause == "6.2.11.6" }
    }

    func test_aMacOsRomanNameAndAPostNameAreNotMistakenForTheCode() throws {
        let mac = fontPage("arial.ttf", "/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [65 /infinity] >>", "32", "(A) Tj", .a2b, patch: macOnly)
        StandardsKit.assertHas(try convert(mac).remaining) { $0.message == PdfAText.trueTypeDifferences }

        let post = fontPage("arial.ttf", "/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [65 /.null] >>", "32", "(A) Tj", .a2b, patch: namedGlyphs)
        StandardsKit.assertHas(try convert(post).remaining) { $0.message == PdfAText.trueTypeDifferences }
    }
}
