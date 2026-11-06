import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeKeepTests.cs: the same cases.

final class OptimizeKeepTests: XCTestCase {
    func test_a_pdfa_1_file_is_not_given_object_streams() throws {
        let document = try PdfDocument.open(StandardsKit.compliant(.a1b))

        let result = try PdfOptimizer(document).run(OptimizeOptions.for(.balanced))

        XCTAssertFalse(TestPdf.text(result.bytes).contains("/ObjStm"))
    }

    func test_a_jpeg_with_a_decode_array_is_left_in_colour_when_made_gray() throws {
        let file = OptimizeKit.build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Decode [1 0 1 0 1 0] /Filter /DCTDecode", OptimizeKit.tinyJpeg)
        })
        let document = try PdfDocument.open(file)

        let result = try PdfOptimizer(document, OptimizeFakeCodec()).run(OptimizeOptions.for(.balanced).with { $0.grayscale = true })

        let after = try PdfDocument.open(result.bytes)
        let image = try OptimizeKit.image(after)
        XCTAssertEqual("DeviceRGB", after.name(image.dictionary, "ColorSpace"))
        XCTAssertTrue(image.dictionary.containsKey("Decode"))
    }
}
