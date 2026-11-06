import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeFontTests.cs: the same cases, with the fixture font of
// FixtureFonts in place of arial.ttf (every glyph is a box, so the size checks compare with the size before rather than
// a fifth of it, and the accented glyph is not a composite: ComponentsOfACompositeGlyphAreKept runs on a font made in
// the test). The PdfPig text assertions have no twin; the engine's own text is compared in their place.

final class OptimizeFontTests: XCTestCase {
    private let arial = FixtureFonts.arial

    private func widths(_ tt: TrueTypeFont) -> String {
        (32..<127).map { String(tt.getAdvance(tt.glyphForCodePoint($0)) * 1000 / tt.unitsPerEm) }.joined(separator: " ")
    }

    private let fontDescriptor =
        "<</Type /FontDescriptor /FontName /Arial /Flags 32 /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 7 0 R>>"

    private func addSimpleFont(_ pdf: TestPdf) {
        let tt = TrueTypeFont.tryParse(arial)!
        pdf.obj(5, "<</Type /Font /Subtype /TrueType /BaseFont /Arial /FirstChar 32 /LastChar 126 /Widths [\(widths(tt))] /FontDescriptor 6 0 R /Encoding /WinAnsiEncoding>>")
        pdf.obj(6, fontDescriptor)
        pdf.stream(7, "/Filter /FlateDecode /Length1 \(arial.count)", TestPdf.deflate(arial))
    }

    private func fontProgram(_ file: [UInt8]) throws -> [UInt8] {
        let after = try PdfDocument.open(file)
        let font = try XCTUnwrap(after.dict(after.dict(after.pages[0].resources, "Font"), "F1"))
        return try after.data(try XCTUnwrap(after.stream(after.dict(font, "FontDescriptor"), "FontFile2")))
    }

    func test_simpleFontKeepsTheGlyphsOfItsText() throws {
        let file = OptimizeKit.build("BT /F1 18 Tf 10 100 Td (Hello World) Tj ET", "/Font <</F1 5 0 R>>", { self.addSimpleFont($0) })
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.subsetFonts = true })
        XCTAssertEqual(1, result.steps.first { $0.kind == .subsetFonts }?.count)
        XCTAssertTrue(result.sizeAfter < result.sizeBefore, "\(result.sizeAfter) \(result.sizeBefore)")
        XCTAssertEqual(try OptimizeKit.engineText(file), try OptimizeKit.engineText(result.bytes))
        let trimmed = try XCTUnwrap(TrueTypeFont.tryParse(try fontProgram(result.bytes)))
        let original = try XCTUnwrap(TrueTypeFont.tryParse(arial))
        XCTAssertEqual(original.glyphCount, trimmed.glyphCount)
        for c in "Helo Wrd".unicodeScalars {
            let gid = original.glyphForCodePoint(Int(c.value))
            XCTAssertEqual(gid, trimmed.glyphForCodePoint(Int(c.value)))
            XCTAssertEqual(original.getAdvance(gid), trimmed.getAdvance(gid))
            XCTAssertEqual(original.getBounds(gid), trimmed.getBounds(gid))
        }
        XCTAssertNil(trimmed.getBounds(original.glyphForCodePoint(Int(UnicodeScalar("Z").value))))
    }

    func test_programUsedOnTwoPagesKeepsTheGlyphsOfBoth() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200] /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 8 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 9 0 R>>")
        addSimpleFont(pdf)
        pdf.stream(8, "", "BT /F1 18 Tf 10 100 Td (abc) Tj ET")
        pdf.stream(9, "", "BT /F1 18 Tf 10 100 Td (xyz) Tj ET")
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.subsetFonts = true })
        let trimmed = try XCTUnwrap(TrueTypeFont.tryParse(try fontProgram(result.bytes)))
        let original = try XCTUnwrap(TrueTypeFont.tryParse(arial))
        for c in "abcxyz".unicodeScalars { XCTAssertNotNil(trimmed.getBounds(original.glyphForCodePoint(Int(c.value)))) }
        XCTAssertNil(trimmed.getBounds(original.glyphForCodePoint(Int(UnicodeScalar("Q").value))))
        let text = try OptimizeKit.engineText(result.bytes)
        XCTAssertTrue(text.contains("abc") && text.contains("xyz"), text)
    }

    func test_compositeFontKeepsTheGlyphsOfItsCodes() throws {
        let tt = try XCTUnwrap(TrueTypeFont.tryParse(arial))
        let hex = "Hi".unicodeScalars.map { String(format: "%04X", tt.glyphForCodePoint(Int($0.value))) }.joined()
        let file = OptimizeKit.build("BT /F1 18 Tf 10 100 Td <\(hex)> Tj ET", "/Font <</F1 5 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /Identity-H /DescendantFonts [8 0 R]>>")
            pdf.obj(8, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /FontDescriptor 6 0 R /CIDToGIDMap /Identity /DW 600>>")
            pdf.obj(6, self.fontDescriptor)
            pdf.stream(7, "/Filter /FlateDecode /Length1 \(self.arial.count)", TestPdf.deflate(self.arial))
        })
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.subsetFonts = true })
        XCTAssertTrue(result.sizeAfter < result.sizeBefore)
        let after = try PdfDocument.open(result.bytes)
        let font = try XCTUnwrap(after.dict(after.dict(after.pages[0].resources, "Font"), "F1"))
        let descendant = try XCTUnwrap(after.resolve(after.array(font, "DescendantFonts")?.items.first) as? PdfDictionary)
        let program = try after.data(try XCTUnwrap(after.stream(after.dict(descendant, "FontDescriptor"), "FontFile2")))
        let trimmed = try XCTUnwrap(TrueTypeFont.tryParse(program))
        XCTAssertNotNil(trimmed.getBounds(tt.glyphForCodePoint(Int(UnicodeScalar("H").value))))
        XCTAssertNil(trimmed.getBounds(tt.glyphForCodePoint(Int(UnicodeScalar("Z").value))))
    }

    // Three glyphs after .notdef: a drawn one, a composite of it, and one nothing uses.
    private func compositeFont() -> [UInt8] {
        func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { u16(v >> 16) + u16(v) }
        let simple = u16(1) + u16(0) + u16(0) + u16(100) + u16(100) + u16(3) + u16(0) + [1, 1, 1, 1] + u16(0) + u16(100) + u16(0) + u16(100)
        let composite = u16(0xFFFF) + u16(0) + u16(0) + u16(100) + u16(100) + u16(0) + u16(1) + [0, 0]
        let spare = simple
        let glyphs = [[UInt8](), simple, composite, spare]
        var glyf: [UInt8] = []
        var loca: [UInt8] = []
        for glyph in glyphs {
            loca += u16(glyf.count / 2)
            glyf += glyph
            if glyf.count % 2 != 0 { glyf.append(0) }
        }
        loca += u16(glyf.count / 2)
        var head = [UInt8](repeating: 0, count: 54)
        head[50] = 0
        var maxp = [UInt8](repeating: 0, count: 32)
        maxp[4] = 0
        maxp[5] = UInt8(glyphs.count)
        let tables: [(tag: String, data: [UInt8])] = [("glyf", glyf), ("head", head), ("loca", loca), ("maxp", maxp)]
        var directory = u32(0x00010000) + u16(tables.count) + u16(64) + u16(2) + u16(0)
        var body: [UInt8] = []
        let base = 12 + 16 * tables.count
        for table in tables {
            directory += Latin1.bytes(table.tag) + u32(0) + u32(base + body.count) + u32(table.data.count)
            body += table.data
            while body.count % 4 != 0 { body.append(0) }
        }
        return directory + body
    }

    func test_componentsOfACompositeGlyphAreKept() throws {
        let font = compositeFont()
        let trimmed = try XCTUnwrap(TrueTypeTrim.trim(font, [2]))
        func table(_ tag: String) -> [UInt8] {
            let count = Int(trimmed[4]) << 8 | Int(trimmed[5])
            for i in 0..<count {
                let at = 12 + 16 * i
                guard Latin1.string(Array(trimmed[at..<at + 4])) == tag else { continue }
                let offset = (Int(trimmed[at + 8]) << 24) | (Int(trimmed[at + 9]) << 16) | (Int(trimmed[at + 10]) << 8) | Int(trimmed[at + 11])
                let length = (Int(trimmed[at + 12]) << 24) | (Int(trimmed[at + 13]) << 16) | (Int(trimmed[at + 14]) << 8) | Int(trimmed[at + 15])
                return Array(trimmed[offset..<offset + length])
            }
            return []
        }
        let loca = table("loca")
        func start(_ glyph: Int) -> Int { (Int(loca[4 * glyph]) << 24) | (Int(loca[4 * glyph + 1]) << 16) | (Int(loca[4 * glyph + 2]) << 8) | Int(loca[4 * glyph + 3]) }
        func length(_ glyph: Int) -> Int { start(glyph + 1) - start(glyph) }
        XCTAssertEqual(0, length(0))
        XCTAssertTrue(length(1) > 0, "the component of the composite glyph is kept")
        XCTAssertTrue(length(2) > 0)
        XCTAssertEqual(0, length(3), "a glyph nothing uses is emptied")
        XCTAssertEqual(1, Int(table("head")[51]), "the offsets are long")
    }

    func test_fontAlsoListedInTheFormIsLeftWhole() throws {
        let file = OptimizeKit.build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>>", { self.addSimpleFont($0) },
                                     catalogExtra: "/AcroForm <</Fields [] /DR <</Font <</Arial 5 0 R>>>>>>")
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.subsetFonts = true })
        XCTAssertEqual(0, result.steps.first { $0.kind == .subsetFonts }?.count)
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialFonts))
        XCTAssertEqual(arial.count, try fontProgram(result.bytes).count)
    }

    func test_fontThatForbidsSubsettingIsLeftWhole() throws {
        var forbidding = arial
        let tt = try XCTUnwrap(TrueTypeFont.tryParse(arial))
        XCTAssertTrue(tt.subsettingAllowed)
        let count = Int(forbidding[4]) << 8 | Int(forbidding[5])
        for i in 0..<count {
            let entry = 12 + 16 * i
            if Latin1.string(Array(forbidding[entry..<entry + 4])) != "OS/2" { continue }
            let offset = Int(forbidding[entry + 8]) << 24 | Int(forbidding[entry + 9]) << 16 | Int(forbidding[entry + 10]) << 8 | Int(forbidding[entry + 11])
            forbidding[offset + 8] = 0x01
            forbidding[offset + 9] = 0x00
        }
        XCTAssertFalse(try XCTUnwrap(TrueTypeFont.tryParse(forbidding)).subsettingAllowed)
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.stream(4, "", "BT /F1 18 Tf 10 100 Td (Hello) Tj ET")
        pdf.obj(5, "<</Type /Font /Subtype /TrueType /BaseFont /Arial /FirstChar 32 /LastChar 32 /Widths [278] /FontDescriptor 6 0 R /Encoding /WinAnsiEncoding>>")
        pdf.obj(6, fontDescriptor)
        pdf.stream(7, "/Filter /FlateDecode", TestPdf.deflate(forbidding))
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.subsetFonts = true })
        XCTAssertEqual(0, result.steps.first { $0.kind == .subsetFonts }?.count)
    }
}
