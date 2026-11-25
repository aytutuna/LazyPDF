import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeUnseenFontTests.cs: the same cases, with the fixture font of
// FixtureFonts in place of arial.ttf.

final class OptimizeUnseenFontTests: XCTestCase {
    private let arial = FixtureFonts.arial
    private let descriptor =
        "<</Type /FontDescriptor /FontName /Arial /Flags 32 /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 7 0 R>>"
    private let subset = OptimizeKit.off.with { $0.subsetFonts = true }

    private func font(_ extra: String = "", baseFont: String = "Arial") -> String {
        "/Subtype /TrueType /BaseFont /\(baseFont) /FirstChar 32 /LastChar 32 /Widths [278] /FontDescriptor 6 0 R /Encoding /WinAnsiEncoding \(extra)"
    }

    private func program(_ pdf: TestPdf) {
        pdf.obj(6, descriptor)
        pdf.stream(7, "/Filter /FlateDecode /Length1 \(arial.count)", TestPdf.deflate(arial))
    }

    private func largest(_ file: [UInt8]) throws -> [UInt8] {
        let after = try PdfDocument.open(file)
        let programs = try after.objectNumbers.compactMap { after.get($0) as? PdfStream }
            .filter { $0.dictionary.containsKey("Length1") }.map { try after.data($0) }
        return try XCTUnwrap(programs.max { $0.count < $1.count })
    }

    private func has(_ program: [UInt8], _ c: Character) throws -> Bool {
        let code = Int(try XCTUnwrap(c.unicodeScalars.first).value)
        return try XCTUnwrap(TrueTypeFont.tryParse(program)).getBounds(try XCTUnwrap(TrueTypeFont.tryParse(arial)).glyphForCodePoint(code)) != nil
    }

    private func run(_ file: [UInt8]) throws -> OptimizeResult {
        try PdfOptimizer(try PdfDocument.open(file)).run(subset)
    }

    func test_a_font_used_only_inside_a_soft_mask_group_keeps_its_glyphs() throws {
        let file = OptimizeKit.build("/GS1 gs BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>> /ExtGState <</GS1 8 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            self.program(pdf)
            pdf.obj(8, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 9 0 R>>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Group <</S /Transparency /CS /DeviceGray>> /Resources <</Font <</F2 5 0 R>>>>",
                       "BT /F2 18 Tf 10 50 Td (Zed) Tj ET")
        })
        let result = try run(file)
        let program = try largest(result.bytes)
        XCTAssertTrue(try has(program, "Z") && has(program, "H"))
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialFonts))
    }

    func test_a_font_used_only_by_a_hidden_appearance_state_keeps_its_glyphs() throws {
        let file = OptimizeKit.build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            self.program(pdf)
            pdf.obj(8, "<</Type /Annot /Subtype /Widget /Rect [10 10 50 50] /AS /Off /AP <</N <</On 9 0 R /Off 10 0 R>>>>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources <</Font <</F2 5 0 R>>>>", "BT /F2 12 Tf 2 2 Td (Q) Tj ET")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "")
        }, pageExtra: "/Annots [8 0 R]")
        let result = try run(file)
        XCTAssertTrue(try has(try largest(result.bytes), "Q"))
    }

    func test_a_font_still_shrinks_when_every_table_naming_it_was_walked() throws {
        let file = OptimizeKit.build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET /Fm0 Do", "/Font <</F1 5 0 R>> /XObject <</Fm0 8 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            self.program(pdf)
            pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources <</Font <</F2 5 0 R>>>>", "BT /F2 12 Tf 2 2 Td (abc) Tj ET")
        })
        let result = try run(file)
        let program = try largest(result.bytes)
        XCTAssertTrue(try has(program, "a") && has(program, "H"))
        XCTAssertFalse(try has(program, "Z"))
    }

    private func twoPages(_ firstFonts: String, _ secondFonts: String, _ more: (TestPdf) -> Void) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 8 0 R /Resources <</Font \(firstFonts)>>>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 9 0 R /Resources <</Font \(secondFonts)>>>>")
        pdf.stream(8, "", "BT /F1 18 Tf 10 100 Td (abc) Tj ET")
        pdf.stream(9, "", "BT /F2 18 Tf 10 100 Td (xyz) Tj ET")
        program(pdf)
        more(pdf)
        return pdf.finish()
    }

    func test_a_font_written_directly_in_a_table_counts_toward_a_shared_program() throws {
        let file = twoPages("<</F1 5 0 R>>", "<</F2 <</Type /Font \(font())>>>>") { pdf in pdf.obj(5, "<</Type /Font " + self.font() + ">>") }
        let program = try largest(try run(file).bytes)
        XCTAssertTrue(try has(program, "a") && has(program, "x") && has(program, "z"))
        XCTAssertFalse(try has(program, "Q"))
    }

    func test_a_font_without_a_type_counts_toward_a_shared_program() throws {
        let file = twoPages("<</F1 5 0 R>>", "<</F2 10 0 R>>") { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            pdf.obj(10, "<<" + self.font() + ">>")
        }
        let program = try largest(try run(file).bytes)
        XCTAssertTrue(try has(program, "a") && has(program, "x") && has(program, "z"))
    }

    func test_a_program_shared_with_a_subset_tagged_font_is_left_whole() throws {
        let file = twoPages("<</F1 5 0 R>>", "<</F2 10 0 R>>") { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            pdf.obj(10, "<</Type /Font " + self.font(baseFont: "ABCDEF+Arial") + ">>")
        }
        XCTAssertEqual(arial.count, try largest(try run(file).bytes).count)
    }

    private func shared(_ content: String, _ extra: String, _ more: @escaping (TestPdf) -> Void, pageExtra: String = "", contents: String = "4 0 R") -> [UInt8] {
        OptimizeKit.build(content, "/Font <</F1 5 0 R>> " + extra, { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            self.program(pdf)
            more(pdf)
        }, pageExtra: pageExtra, contents: contents, shared: true)
    }

    func test_a_soft_mask_group_sharing_the_page_resources_keeps_the_glyphs() throws {
        let file = shared("/GS1 gs BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/ExtGState <</GS1 8 0 R>>", { pdf in
            pdf.obj(8, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 9 0 R>>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Group <</S /Transparency /CS /DeviceGray>> /Resources 12 0 R", "BT /F1 18 Tf 10 50 Td (Zed) Tj ET")
        })
        let result = try run(file)
        let program = try largest(result.bytes)
        XCTAssertTrue(try has(program, "Z") && has(program, "H"))
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialFonts))
    }

    func test_a_hidden_appearance_state_sharing_the_page_resources_keeps_the_glyphs() throws {
        let file = shared("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "", { pdf in
            pdf.obj(8, "<</Type /Annot /Subtype /Widget /Rect [10 10 50 50] /AS /Off /AP <</N <</On 9 0 R /Off 10 0 R>>>>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources 12 0 R", "BT /F1 12 Tf 2 2 Td (Q) Tj ET")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources 12 0 R", "")
        }, pageExtra: "/Annots [8 0 R]")
        XCTAssertTrue(try has(try largest(try run(file).bytes), "Q"))
    }

    func test_an_appearance_without_resources_uses_the_page_fonts() throws {
        let file = shared("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "", { pdf in
            pdf.obj(8, "<</Type /Annot /Subtype /FreeText /Rect [10 10 50 50] /AP <</N 9 0 R>>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "BT /F1 12 Tf 2 2 Td (Q) Tj ET")
        }, pageExtra: "/Annots [8 0 R]")
        let result = try run(file)
        let program = try largest(result.bytes)
        XCTAssertTrue(try has(program, "Q") && has(program, "H"))
        XCTAssertFalse(result.notes.contains(OptimizeText.leftPartialFonts))
    }

    func test_a_page_stream_that_cannot_be_read_leaves_the_fonts_whole() throws {
        let file = shared("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "", { pdf in pdf.stream(8, "/Filter /FlateDecode", "not deflate data") }, contents: "[4 0 R 8 0 R]")
        let result = try run(file)
        XCTAssertEqual(arial.count, try largest(result.bytes).count)
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialFonts))
    }

    func test_a_form_that_cannot_be_read_leaves_the_fonts_whole() throws {
        let file = OptimizeKit.build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET /Fm0 Do", "/Font <</F1 5 0 R>> /XObject <</Fm0 8 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            self.program(pdf)
            pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Filter /FlateDecode /Resources <</Font <</F2 5 0 R>>>>", "not deflate data")
        })
        XCTAssertEqual(arial.count, try largest(try run(file).bytes).count)
    }

    // A page whose run ends at the operation limit shows nothing after it.
    private func spin(_ times: Int) -> String { String(repeating: "/Fm0 Do\n", count: times) }

    private func spinner(_ pdf: TestPdf) {
        pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 1 1]", String(repeating: "q Q ", count: 50))
    }

    func test_a_page_run_cut_short_leaves_the_fonts_whole() throws {
        let file = OptimizeKit.build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET\n" + spin(100_000) + "BT /F1 18 Tf 10 50 Td (Zed) Tj ET", "/Font <</F1 5 0 R>> /XObject <</Fm0 8 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            self.program(pdf)
            self.spinner(pdf)
        })
        XCTAssertEqual(arial.count, try largest(try run(file).bytes).count)
    }

    func test_an_appearance_run_cut_short_leaves_the_fonts_whole() throws {
        let file = OptimizeKit.build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            self.program(pdf)
            self.spinner(pdf)
            pdf.obj(9, "<</Type /Annot /Subtype /Widget /Rect [10 10 50 50] /AP <</N 10 0 R>>>>")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources <</Font <</F1 5 0 R>> /XObject <</Fm0 8 0 R>>>>",
                       self.spin(100_000) + "BT /F1 12 Tf 2 2 Td (Q) Tj ET")
        }, pageExtra: "/Annots [9 0 R]")
        XCTAssertEqual(arial.count, try largest(try run(file).bytes).count)
    }

    func test_a_glyph_procedure_without_resources_leaves_the_fonts_whole() throws {
        let file = OptimizeKit.build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET BT /T3 10 Tf (a) Tj ET", "/Font <</F1 5 0 R /T3 8 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            self.program(pdf)
            pdf.obj(8, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] /CharProcs <</a 9 0 R>> /Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [1]>>")
            pdf.stream(9, "", "1 0 d0 BT /F1 1 Tf (Z) Tj ET")
        })
        XCTAssertEqual(arial.count, try largest(try run(file).bytes).count)
    }

    func test_a_font_written_directly_in_a_graphics_state_blocks_the_shared_program() throws {
        let file = OptimizeKit.build("/GS1 gs BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>> /ExtGState <</GS1 8 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            self.program(pdf)
            pdf.obj(8, "<</Type /ExtGState /Font [<</Type /Font \(self.font())>> 12]>>")
        })
        XCTAssertEqual(arial.count, try largest(try run(file).bytes).count)
    }

    func test_a_default_resources_font_blocks_the_shared_program() throws {
        let file = OptimizeKit.build("BT /F1 18 Tf 10 100 Td (Hello) Tj ET", "/Font <</F1 5 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font " + self.font() + ">>")
            self.program(pdf)
        }, catalogExtra: "/AcroForm <</Fields [] /DR <</Font <</Helv <</Type /Font \(font())>>>>>>>>")
        XCTAssertEqual(arial.count, try largest(try run(file).bytes).count)
    }
}
