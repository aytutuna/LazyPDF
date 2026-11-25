import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeUnseenImageTests.cs: the same cases.

final class OptimizeUnseenImageTests: XCTestCase {
    private let downsample = OptimizeKit.off.with { $0.imageDpi = 72; $0.imageDpiAbove = 100 }

    private func rgb(_ size: Int, _ extra: String = "") -> String {
        "/Type /XObject /Subtype /Image /Width \(size) /Height \(size) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode \(extra)"
    }

    private func widthAfter(_ file: [UInt8], _ options: OptimizeOptions) throws -> Int {
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(options)
        let after = try PdfDocument.open(result.bytes)
        return after.integer(try OptimizeKit.image(after).dictionary, "Width") ?? 0
    }

    func test_a_page_unit_scales_the_placed_size() throws {
        let file = OptimizeKit.build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>",
                                     { pdf in pdf.stream(5, self.rgb(800), TestPdf.deflate(OptimizeKit.gradient(800, 800, 3))) }, pageExtra: "/UserUnit 10")
        // 800 pixels over 800 points are 72 dpi, which is what is asked for.
        XCTAssertEqual(800, try widthAfter(file, downsample))
    }

    func test_an_image_also_painted_large_in_a_soft_mask_group_keeps_its_pixels() throws {
        let file = OptimizeKit.build("/GS1 gs q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>> /ExtGState <</GS1 8 0 R>>", { pdf in
            pdf.stream(5, self.rgb(200), TestPdf.deflate(OptimizeKit.gradient(200, 200, 3)))
            pdf.obj(8, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 9 0 R>>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Group <</S /Transparency /CS /DeviceRGB>> /Resources <</XObject <</Im0 5 0 R>>>>",
                       "q 200 0 0 200 0 0 cm /Im0 Do Q")
        })
        XCTAssertEqual(200, try widthAfter(file, downsample))
    }

    func test_an_image_reached_by_a_type_3_glyph_through_an_indirect_table_is_left() throws {
        let file = OptimizeKit.build("q 100 0 0 100 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", { pdf in
            pdf.stream(5, self.rgb(200), TestPdf.deflate(OptimizeKit.gradient(200, 200, 3)))
            pdf.obj(6, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] /CharProcs <</a 7 0 R>> /Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [1] /Resources <</XObject 8 0 R>>>>")
            pdf.stream(7, "", "1 0 d0 q 1 0 0 1 0 0 cm /Im0 Do Q")
            pdf.obj(8, "<</Im0 5 0 R>>")
        })
        XCTAssertEqual(200, try widthAfter(file, downsample))
    }

    func test_a_soft_mask_that_declares_a_huge_size_is_left_and_the_image_with_it() throws {
        let file = OptimizeKit.build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            pdf.stream(5, self.rgb(200, "/SMask 6 0 R"), TestPdf.deflate(OptimizeKit.gradient(200, 200, 3)))
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 60000 /Height 60000 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode",
                       TestPdf.deflate(Array(repeating: 0, count: 16)))
        })
        XCTAssertEqual(200, try widthAfter(file, downsample))
    }

    func test_an_image_whose_mask_has_a_matte_is_not_resized() throws {
        let file = OptimizeKit.build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            pdf.stream(5, self.rgb(200, "/SMask 6 0 R"), TestPdf.deflate(OptimizeKit.gradient(200, 200, 3)))
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 200 /Height 200 /ColorSpace /DeviceGray /BitsPerComponent 8 /Matte [0 0 0] /Filter /FlateDecode",
                       TestPdf.deflate(OptimizeKit.gradient(200, 200, 1)))
        })
        XCTAssertEqual(200, try widthAfter(file, downsample))
    }

    func test_a_two_colour_image_with_a_matte_stays_eight_bit() throws {
        let black = Array(repeating: UInt8(0), count: 20 * 20 * 3)
        let file = OptimizeKit.build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            pdf.stream(5, self.rgb(20, "/SMask 6 0 R"), TestPdf.deflate(black))
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 20 /Height 20 /ColorSpace /DeviceGray /BitsPerComponent 8 /Matte [0 0 0] /Filter /FlateDecode",
                       TestPdf.deflate(Array(repeating: 0, count: 400)))
        })
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.bilevelTolerance = 8 })
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual("DeviceRGB", after.name(try OptimizeKit.image(after).dictionary, "ColorSpace"))
    }

    private func picture(_ pdf: TestPdf) {
        pdf.stream(5, rgb(200), TestPdf.deflate(OptimizeKit.gradient(200, 200, 3)))
    }

    private func run(_ file: [UInt8]) throws -> OptimizeResult {
        let document = try PdfDocument.open(file)
        return try PdfOptimizer(document).run(downsample)
    }

    private func widthOf(_ result: OptimizeResult) throws -> Int {
        let after = try PdfDocument.open(result.bytes)
        return after.integer(try OptimizeKit.image(after).dictionary, "Width") ?? 0
    }

    func test_a_soft_mask_group_sharing_the_page_resources_leaves_the_image_alone() throws {
        let file = OptimizeKit.build("/GS1 gs q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>> /ExtGState <</GS1 8 0 R>>", { pdf in
            self.picture(pdf)
            pdf.obj(8, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 9 0 R>>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Group <</S /Transparency /CS /DeviceRGB>> /Resources 12 0 R", "q 200 0 0 200 0 0 cm /Im0 Do Q")
        }, shared: true)
        let result = try run(file)
        XCTAssertEqual(200, try widthOf(result))
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialImages))
    }

    func test_a_type_3_font_sharing_the_page_resources_leaves_the_image_alone() throws {
        let file = OptimizeKit.build("q 100 0 0 100 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", { pdf in
            self.picture(pdf)
            pdf.obj(6, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] /CharProcs <</a 7 0 R>> /Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [1] /Resources 12 0 R>>")
            pdf.stream(7, "", "1 0 d0 q 200 0 0 200 0 0 cm /Im0 Do Q")
        }, shared: true)
        XCTAssertEqual(200, try widthOf(try run(file)))
    }

    func test_an_appearance_without_resources_is_measured_with_the_page_resources() throws {
        let file = OptimizeKit.build("q 50 0 0 50 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            self.picture(pdf)
            pdf.obj(8, "<</Type /Annot /Subtype /Stamp /Rect [0 0 200 200] /AP <</N 9 0 R>>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 200]", "q 200 0 0 200 0 0 cm /Im0 Do Q")
        }, pageExtra: "/Annots [8 0 R]")
        XCTAssertEqual(200, try widthOf(try run(file)))
    }

    func test_a_page_stream_that_cannot_be_read_leaves_the_image_alone_and_says_so() throws {
        let file = OptimizeKit.build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            self.picture(pdf)
            pdf.stream(8, "/Filter /FlateDecode", "not deflate data")
        }, contents: "[4 0 R 8 0 R]")
        let result = try run(file)
        XCTAssertEqual(200, try widthOf(result))
        XCTAssertTrue(result.notes.contains(OptimizeText.leftPartialImages))
    }

    func test_an_empty_appearance_state_without_resources_does_not_stop_the_downsampling() throws {
        let file = OptimizeKit.build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            self.picture(pdf)
            pdf.obj(8, "<</Type /Annot /Subtype /Widget /Rect [10 10 50 50] /AS /Yes /AP <</N <</Yes 9 0 R /Off 10 0 R>>>>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 40 40 re S")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "")
        }, pageExtra: "/Annots [8 0 R]")
        let result = try run(file)
        XCTAssertEqual(100, try widthOf(result))
        XCTAssertFalse(result.notes.contains(OptimizeText.leftPartialImages))
    }

    func test_a_soft_mask_with_a_huge_row_is_left_as_it_is() throws {
        for (width, space, bits) in [(134_217_728, "DeviceGray", 16), (100_000_000, "DeviceRGB", 8)] {
            let file = OptimizeKit.build("q 100 0 0 100 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
                pdf.stream(5, self.rgb(200, "/SMask 6 0 R"), TestPdf.deflate(OptimizeKit.gradient(200, 200, 3)))
                pdf.stream(6, "/Type /XObject /Subtype /Image /Width \(width) /Height 1 /ColorSpace /\(space) /BitsPerComponent \(bits) /Filter /FlateDecode",
                           TestPdf.deflate(Array(repeating: 0, count: 16)))
            })
            XCTAssertEqual(100, try widthOf(try run(file)), "\(width) \(space) \(bits)")
        }
    }
}
