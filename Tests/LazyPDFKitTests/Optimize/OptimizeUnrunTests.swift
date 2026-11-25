import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeUnrunTests.cs: the same cases.

final class OptimizeUnrunTests: XCTestCase {
    private let downsample = OptimizeKit.off.with { $0.imageDpi = 72; $0.imageDpiAbove = 100 }
    private let type3 = "/Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] /CharProcs <</a 7 0 R>> /Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [1]"
    private let tiling = "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <</XObject <</Im0 5 0 R>>>>"

    private func picture(_ pdf: TestPdf) {
        pdf.stream(5, "/Type /XObject /Subtype /Image /Width 200 /Height 200 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode",
                   TestPdf.deflate(OptimizeKit.gradient(200, 200, 3)))
    }

    private func run(_ file: [UInt8]) throws -> OptimizeResult {
        let document = try PdfDocument.open(file)
        return try PdfOptimizer(document).run(downsample)
    }

    private func widthOf(_ result: OptimizeResult) throws -> Int {
        let after = try PdfDocument.open(result.bytes)
        let images = after.objectNumbers.compactMap { after.get($0) as? PdfStream }.filter { OptimizeKit.isImage(after, $0) }
        XCTAssertEqual(1, images.count)
        return after.integer(try XCTUnwrap(images.first).dictionary, "Width") ?? 0
    }

    private func hiddenState(_ pdf: TestPdf, _ onEntries: String, _ onContent: String) {
        pdf.obj(8, "<</Type /Annot /Subtype /Widget /Rect [10 10 50 50] /AS /Off /AP <</N <</On 9 0 R /Off 10 0 R>>>>>>")
        pdf.stream(9, onEntries, onContent)
        pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "")
    }

    func test_a_hidden_state_with_no_subtype_counts_as_a_form_that_never_ran() throws {
        let file = OptimizeKit.build("q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            self.picture(pdf)
            self.hiddenState(pdf, "/BBox [0 0 40 40] /Resources 12 0 R", "q 200 0 0 200 0 0 cm /Im0 Do Q")
        }, pageExtra: "/Annots [8 0 R]", shared: true)
        let result = try run(file)
        XCTAssertEqual(200, try widthOf(result))
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialImages))
    }

    func test_a_hidden_state_without_resources_that_names_an_image_leaves_the_image_whole() throws {
        let file = OptimizeKit.build("q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            self.picture(pdf)
            self.hiddenState(pdf, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "q 200 0 0 200 0 0 cm /Im0 Do Q")
        }, pageExtra: "/Annots [8 0 R]")
        let result = try run(file)
        XCTAssertEqual(200, try widthOf(result))
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialImages))
    }

    func test_a_hidden_state_without_resources_that_only_draws_a_path_changes_nothing() throws {
        let file = OptimizeKit.build("q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            self.picture(pdf)
            self.hiddenState(pdf, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 10 10 re f")
        }, pageExtra: "/Annots [8 0 R]")
        XCTAssertTrue(try widthOf(try run(file)) < 200)
    }

    func test_a_bitmap_type_3_font_without_resources_does_not_stop_the_downsampling() throws {
        let file = OptimizeKit.build("q 50 0 0 50 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", { pdf in
            self.picture(pdf)
            pdf.obj(6, "<<" + self.type3 + ">>")
            pdf.stream(7, "", "1 0 0 0 1 1 d1 0 0 1 1 re f")
        })
        XCTAssertTrue(try widthOf(try run(file)) < 200)
    }

    func test_a_type_3_glyph_without_resources_that_paints_an_image_leaves_it_whole() throws {
        let file = OptimizeKit.build("q 50 0 0 50 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", { pdf in
            self.picture(pdf)
            pdf.obj(6, "<<" + self.type3 + ">>")
            pdf.stream(7, "", "1 0 d0 q 200 0 0 200 0 0 cm /Im0 Do Q")
        })
        let result = try run(file)
        XCTAssertEqual(200, try widthOf(result))
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialImages))
    }

    func test_a_file_without_images_never_says_images_were_left() throws {
        let file = OptimizeKit.build("BT /T3 10 Tf (a) Tj ET", "/Font <</T3 6 0 R>>", { pdf in
            pdf.obj(6, "<<" + self.type3 + ">>")
            pdf.stream(7, "", "1 0 d0 BT /F1 1 Tf (Z) Tj ET")
        })
        XCTAssertFalse(try run(file).notes.contains(OptimizeText.leftPartialImages))
    }

    func test_an_unseen_image_that_is_small_enough_is_not_reported() throws {
        let file = OptimizeKit.build("q 200 0 0 200 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", { pdf in
            self.picture(pdf)
            pdf.obj(6, "<<" + self.type3 + " /Resources 12 0 R>>")
            pdf.stream(7, "", "1 0 d0 q 200 0 0 200 0 0 cm /Im0 Do Q")
        }, shared: true)
        let result = try run(file)
        XCTAssertEqual(200, try widthOf(result))
        XCTAssertFalse(result.notes.contains(OptimizeText.leftPartialImages))
    }

    func test_a_form_also_used_as_a_soft_mask_group_keeps_the_pixels_it_shows() throws {
        let file = OptimizeKit.build("/GS1 gs q 50 0 0 50 0 0 cm /G Do Q", "/XObject <</G 9 0 R>> /ExtGState <</GS1 8 0 R>>", { pdf in
            self.picture(pdf)
            pdf.obj(8, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 9 0 R>>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Group <</S /Transparency /CS /DeviceRGB>> /Resources <</XObject <</Im0 5 0 R>>>>", "q 1 0 0 1 0 0 cm /Im0 Do Q")
        })
        let result = try run(file)
        XCTAssertEqual(200, try widthOf(result))
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialImages))
    }

    private func tiled(_ content: String, _ twice: Bool) -> [UInt8] {
        let form = "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <</Pattern <</P 9 0 R>>>>"
        return OptimizeKit.build(content, twice ? "/XObject <</Fm0 6 0 R /Fm1 8 0 R>>" : "/XObject <</Fm0 6 0 R>>", { pdf in
            self.picture(pdf)
            pdf.stream(6, form, "/Pattern cs /P scn 0 0 100 100 re f")
            if twice { pdf.stream(8, form, "/Pattern cs /P scn 0 0 100 100 re f") }
            pdf.stream(9, self.tiling, "q 10 0 0 10 0 0 cm /Im0 Do Q")
        })
    }

    func test_a_pattern_painted_at_one_scale_is_measured() throws {
        XCTAssertTrue(try widthOf(try run(tiled("q 0.5 0 0 0.5 0 0 cm /Fm0 Do Q", false))) < 200)
    }

    func test_a_pattern_painted_by_forms_at_two_scales_leaves_its_image_whole() throws {
        let result = try run(tiled("q 0.5 0 0 0.5 0 0 cm /Fm0 Do Q q 10 0 0 10 0 0 cm /Fm1 Do Q", true))
        XCTAssertEqual(200, try widthOf(result))
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialImages))
    }

    func test_a_pattern_a_glyph_procedure_may_paint_elsewhere_leaves_its_image_whole() throws {
        let file = OptimizeKit.build("/Pattern cs /P scn 0 0 100 100 re f", "/Pattern <</P 9 0 R>> /Font <</T3 6 0 R>>", { pdf in
            self.picture(pdf)
            pdf.obj(6, "<<" + self.type3 + " /Resources <</Pattern <</P 9 0 R>>>>>>")
            pdf.stream(7, "", "1 0 d0 /Pattern cs /P scn 0 0 1 1 re f")
            pdf.stream(9, self.tiling, "q 10 0 0 10 0 0 cm /Im0 Do Q")
        })
        let result = try run(file)
        XCTAssertEqual(200, try widthOf(result))
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialImages))
    }
}
