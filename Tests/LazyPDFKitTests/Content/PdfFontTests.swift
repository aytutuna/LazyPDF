import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/PdfFontTests.cs: the same cases. The two tests that read an installed
// arial.ttf read the synthetic font of the font program tests instead (A and B with their widths, the Turkish letters
// ğ and İ), so they run on every runner. ADictionaryGivesTheSameFontEachTime holds the first font while it asks for
// the second: PdfFont.get keeps its fonts weakly.

final class PdfFontTests: XCTestCase {
    private func document(_ objects: [String]) throws -> PdfDocument {
        try ContentTestPdf.page("", "", objects)
    }

    private func fonts(_ more: (TestPdf) -> Void) throws -> PdfDocument {
        try ContentTestPdf.page("", "", more)
    }

    private func font(_ d: PdfDocument, _ number: Int) throws -> PdfFont {
        PdfFont.get(d, try XCTUnwrap(d.get(number) as? PdfDictionary))
    }

    private func b(_ s: String) -> [UInt8] { Latin1.bytes(s) }

    func test_standardFontWidthsAndTextWithoutAWidthsArray() throws {
        let d = try document(["<</Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold>>"])
        let f = try font(d, 5)
        let chars = f.decode(b("A b"))
        XCTAssertEqual(chars.map { $0.width }, [722.0, 278, 611])
        XCTAssertEqual(f.toText(b("A b")), "A b")
        XCTAssertTrue(f.isBold)
        XCTAssertTrue(chars[1].isSpace)
        XCTAssertFalse(f.isEmbedded)
    }

    func test_windowsNamesMapToTheStandardFonts() throws {
        let d = try document(["<</Type /Font /Subtype /TrueType /BaseFont /ABCDEF+TimesNewRomanPS-BoldMT /Encoding /WinAnsiEncoding>>"])
        let f = try font(d, 5)
        XCTAssertEqual(f.name, "TimesNewRomanPS-BoldMT")
        XCTAssertEqual(f.decode(b("A"))[0].width, 722)
    }

    func test_widthsArrayMissingWidthAndOutOfRangeCodes() throws {
        let d = try document([
            "<</Type /Font /Subtype /Type1 /BaseFont /Foo /FirstChar 65 /LastChar 66 /Widths [500 600] /FontDescriptor 6 0 R>>",
            "<</Type /FontDescriptor /FontName /Foo /Flags 32 /MissingWidth 300 /Ascent 900 /Descent 250 /CapHeight 700>>",
        ])
        let f = try font(d, 5)
        XCTAssertEqual(f.decode(b("ABCa")).map { $0.width }, [500.0, 600, 300, 300])
        XCTAssertEqual(f.ascent, 900)
        XCTAssertEqual(f.descent, -250)
    }

    func test_anUnknownFontWithoutWidthsBorrowsHelveticaMetrics() throws {
        let d = try document(["<</Type /Font /Subtype /Type1 /BaseFont /Foo>>"])
        XCTAssertEqual(try font(d, 5).decode(b("A"))[0].width, 667)
    }

    func test_differencesRenameCodes() throws {
        let d = try document(["<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [65 /Euro /ccedilla 200 /uni011F]>>>>"])
        let f = try font(d, 5)
        XCTAssertEqual(f.toText(b("AB")), "€ç")
        XCTAssertEqual(f.toText([200]), "ğ")
        XCTAssertEqual(f.toText(b("C")), "C")
    }

    func test_winAnsiAndMacRomanDifferInTheUpperHalf() throws {
        let d = try document([
            "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>",
            "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /MacRomanEncoding>>",
        ])
        XCTAssertEqual(try font(d, 5).toText([0xE9]), "é")
        XCTAssertEqual(try font(d, 6).toText([0x8E]), "é")
    }

    func test_toUnicodeWinsOverTheEncoding() throws {
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <00> <FF> endcodespacerange "
            + "2 beginbfchar <41> <005A> <42> <00660069> endbfchar endcmap"
        let d = try fonts { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /ToUnicode 6 0 R>>")
            pdf.stream(6, "", cmap)
        }
        let f = try font(d, 5)
        XCTAssertTrue(f.hasToUnicode)
        XCTAssertEqual(f.toText(b("AB")), "Zfi")
        XCTAssertEqual(f.toText(b("C")), "C")
    }

    func test_type0WithIdentityHReadsWidthsFromW() throws {
        let d = try document([
            "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [6 0 R]>>",
            "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 800 /W [1 [500 600] 10 20 700]>>",
        ])
        let f = try font(d, 5)
        let chars = f.decode([0, 1, 0, 2, 0, 15, 0, 50])
        XCTAssertEqual(chars.map { $0.width }, [500.0, 600, 700, 800])
        XCTAssertEqual(chars.map { $0.cid }, [1, 2, 15, 50])
        for c in chars { XCTAssertEqual(c.length, 2) }
        XCTAssertTrue(f.isComposite)
        XCTAssertFalse(f.isVertical)
    }

    func test_verticalMetricsFromDw2AndW2() throws {
        let d = try document([
            "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-V /DescendantFonts [6 0 R]>>",
            "<</Type /Font /Subtype /CIDFontType0 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 1000 /DW2 [900 -950] /W2 [5 [-500 100 800] 7 8 -600 200 700]>>",
        ])
        let f = try font(d, 5)
        XCTAssertTrue(f.isVertical)
        let c = f.decode([0, 1, 0, 5, 0, 8])
        XCTAssertEqual([c[0].verticalAdvance, c[0].originX, c[0].originY], [-950.0, 500, 900])
        XCTAssertEqual([c[1].verticalAdvance, c[1].originX, c[1].originY], [-500.0, 100, 800])
        XCTAssertEqual([c[2].verticalAdvance, c[2].originX, c[2].originY], [-600.0, 200, 700])
    }

    func test_mixedLengthCMapsCutTheStringByCodespace() throws {
        let d = try document([
            "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /90ms-RKSJ-H /DescendantFonts [6 0 R]>>",
            "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Japan1) /Supplement 2>> /DW 1000>>",
        ])
        let chars = try font(d, 5).decode([0x41, 0x82, 0xA0, 0x42])
        XCTAssertEqual(chars.map { $0.length }, [1, 2, 1])
        XCTAssertEqual(chars[0].unicode, "A")
        XCTAssertEqual(chars[1].unicode, "あ")
    }

    func test_anAdobeCollectionGivesUnicodeWithoutAToUnicodeMap() throws {
        let d = try document([
            "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [6 0 R]>>",
            "<</Type /Font /Subtype /CIDFontType0 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Japan1) /Supplement 2>>>>",
        ])
        XCTAssertEqual(try font(d, 5).toText([0, 34]), "A")
    }

    func test_anEmbeddedCMapStreamIsRead() throws {
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Custom def /WMode 0 def "
            + "1 begincodespacerange <00> <FF> endcodespacerange 1 begincidrange <20> <7E> 100 endcidrange endcmap"
        let d = try fonts { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding 7 0 R /DescendantFonts [6 0 R]>>")
            pdf.obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /DW 500 /W [100 [250]]>>")
            pdf.stream(7, "/Type /CMap /CMapName /Custom", cmap)
        }
        let c = try font(d, 5).decode(b("  "))
        XCTAssertEqual(c.map { $0.length }, [1, 1])
        XCTAssertEqual(c[0].cid, 100)
        XCTAssertEqual(c[0].width, 250)
    }

    func test_brokenFontsNeverThrow() throws {
        let d = try document([
            "<<>>", "<</Type /Font /Subtype /Type0>>", "<</Type /Font /Subtype /Type0 /DescendantFonts [<<>>] /Encoding /NoSuchCMap>>",
            "<</Type /Font /Subtype /TrueType /Widths [/a (b) 3 [4]] /FirstChar -5 /Encoding 3>>",
            "<</Type /Font /Subtype /Type3 /FontMatrix [0 0 0 0 0 0] /Widths 5>>",
            "<</Type /Font /Subtype /Type1 /Encoding <</Differences [/a 99999 /b -4 (x)]>> /ToUnicode 5 0 R>>",
            "<</Type /Font /Subtype /Type0 /DescendantFonts [<</W [1 2 3 [4] 70000 80000 5 -3 /x]>>]>>",
        ])
        for n in [5, 6, 7, 8, 9, 10, 11] {
            let chars = try font(d, n).decode([0, 1, 2, 65, 200, 255, 0, 3])
            XCTAssertFalse(chars.isEmpty)
            for c in chars { XCTAssertTrue(c.length >= 1 && c.width.isFinite, "font \(n)") }
        }
    }

    func test_readAlwaysMakesProgress() throws {
        let d = try document(["<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /UniJIS-UTF16-H /DescendantFonts [<<>>]>>"])
        let f = try font(d, 5)
        var bytes: ArraySlice<UInt8> = [0xD8, 0x00, 0xFF]
        var total = 0
        while !bytes.isEmpty {
            let (used, _) = f.read(bytes)
            XCTAssertGreaterThan(used, 0)
            bytes = bytes.dropFirst(used)
            total += 1
        }
        XCTAssertGreaterThanOrEqual(total, 1)
        XCTAssertEqual(f.read(ArraySlice<UInt8>()).used, 0)
    }

    func test_aDictionaryGivesTheSameFontEachTime() throws {
        let d = try document([ContentTestPdf.helvetica])
        let first = try font(d, 5)
        let second = try font(d, 5)
        assertSame(first, second)
    }

    func test_subtypeIsGuessedWhenMissing() throws {
        let d = try document(["<</BaseFont /Helvetica>>", "<</DescendantFonts [<<>>]>>"])
        XCTAssertEqual(try font(d, 5).subtype, "Type1")
        XCTAssertEqual(try font(d, 6).subtype, "Type0")
    }

    func test_wholeTrueTypeFileGivesUnicodeFromItsCmap() throws {
        let bytes = try SyntheticFonts.ttf()
        let tt = try XCTUnwrap(TrueTypeFont.tryParse(bytes))
        let gid = tt.glyphForCodePoint(0x11F)
        let d = try fonts { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /Identity-H /DescendantFonts [6 0 R]>>")
            pdf.obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /FontDescriptor 7 0 R /CIDToGIDMap /Identity>>")
            pdf.obj(7, "<</Type /FontDescriptor /FontName /Arial /Flags 32 /FontFile2 8 0 R>>")
            pdf.stream(8, "", bytes)
        }
        let f = try font(d, 5)
        XCTAssertTrue(f.isEmbedded)
        XCTAssertEqual(f.toText([UInt8(truncatingIfNeeded: gid >> 8), UInt8(truncatingIfNeeded: gid)]), "ğ")
    }

    func test_embeddedSimpleTrueTypeWithoutEncodingReadsItsCmapBack() throws {
        let bytes = try SyntheticFonts.ttf()
        let d = try fonts { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /TrueType /BaseFont /Arial /FontDescriptor 6 0 R>>")
            pdf.obj(6, "<</Type /FontDescriptor /FontName /Arial /Flags 4 /FontFile2 7 0 R>>")
            pdf.stream(7, "", bytes)
        }
        let f = try font(d, 5)
        XCTAssertEqual(f.toText(b("AB")), "AB")
        XCTAssertGreaterThan(f.decode(b("A"))[0].width, 0)
    }
}
