import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeContentSplitTests.cs: the same cases.

final class OptimizeContentSplitTests: XCTestCase {
    private func run(_ file: [UInt8], _ options: OptimizeOptions) throws -> PdfDocument {
        let document = try PdfDocument.open(file)
        return try PdfDocument.open(try PdfOptimizer(document).run(options).bytes)
    }

    func test_an_operator_in_the_next_content_stream_still_names_its_operand() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents [4 0 R 5 0 R] /Resources <</XObject <</Im0 6 0 R>>>>>>")
        pdf.stream(4, "", "q 10 0 0 10 0 0 cm /Im0")
        pdf.stream(5, "", "Do Q")
        pdf.stream(6, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", "\0")
        let after = try run(pdf.finish(), OptimizeKit.off.with { $0.pruneResources = true })
        XCTAssertEqual(true, after.dict(after.pages[0].resources, "XObject")?.containsKey("Im0"))
    }

    func test_the_base_space_of_an_inline_indexed_image_is_kept() throws {
        let content = "q 10 0 0 10 0 0 cm BI /W 1 /H 1 /BPC 8 /CS [/I /Cs0 1 <000000ffffff>] ID \0 EI Q"
        let file = OptimizeKit.build(content, "/ColorSpace <</Cs0 /DeviceRGB /Unused /DeviceGray>>")
        let after = try run(file, OptimizeKit.off.with { $0.pruneResources = true })
        let spaces = try XCTUnwrap(after.dict(after.pages[0].resources, "ColorSpace"))
        XCTAssertTrue(spaces.containsKey("Cs0"))
        XCTAssertFalse(spaces.containsKey("Unused"))
    }

    func test_a_colour_set_in_a_space_that_cannot_be_looked_up_keeps_all_its_operands() throws {
        let file = OptimizeKit.build("/Fm0 Do", "/XObject <</Fm0 5 0 R>>", { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "/Cs1 cs 0.5 0.5 0.5 sc 0 0 5 5 re f")
        })
        let after = try run(file, OptimizeKit.off.with { $0.grayscale = true })
        let xobjects = try XCTUnwrap(after.dict(after.pages[0].resources, "XObject"))
        let form = try XCTUnwrap(after.resolve(xobjects["Fm0"]) as? PdfStream)
        let sets = ContentParser.parse(try after.data(form)).filter { $0.operator == "sc" }
        XCTAssertEqual(1, sets.count)
        XCTAssertEqual(3, sets[0].operands.count)
    }

    func test_a_matte_follows_the_image_to_gray() throws {
        let dictionary = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /BitsPerComponent 8 /Filter /FlateDecode"
        let file = OptimizeKit.build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            pdf.stream(5, dictionary + " /ColorSpace /DeviceRGB /SMask 6 0 R", TestPdf.deflate(OptimizeKit.gradient(8, 8, 3)))
            pdf.stream(6, dictionary + " /ColorSpace /DeviceGray /Matte [1 0 0]", TestPdf.deflate(OptimizeKit.gradient(8, 8, 1)))
        })
        let after = try run(file, OptimizeKit.off.with { $0.grayscale = true })
        let image = try OptimizeKit.image(after)
        XCTAssertEqual("DeviceGray", after.name(image.dictionary, "ColorSpace"))
        let soft = try XCTUnwrap(after.stream(image.dictionary, "SMask"))
        let matte = try XCTUnwrap(after.array(soft.dictionary, "Matte"))
        XCTAssertEqual(1, matte.items.count)
        let value = try XCTUnwrap(matte.items[0] as? PdfNumber)
        XCTAssertEqual(0.299, value.value, accuracy: 0.0005)
    }
}
