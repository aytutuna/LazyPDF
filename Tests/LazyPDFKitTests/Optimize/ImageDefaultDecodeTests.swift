import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/ImageDefaultDecodeTests.cs.

final class ImageDefaultDecodeTests: XCTestCase {
    func test_eachSpacesOwnDefaultIsRecognised() throws {
        let indexed = "[/Indexed /DeviceRGB 1 <000000FFFFFF>]"
        let lab = "[/Lab <</WhitePoint [0.95 1 1.09]>>]"
        let ranged = "[/Lab <</WhitePoint [0.95 1 1.09] /Range [-50 50 -60 60]>>]"
        let cases: [(String, Int, [Double], Bool)] = [
            ("/DeviceGray", 8, [0, 1], true),
            ("/DeviceGray", 8, [1, 0], false),
            ("/DeviceRGB", 8, [0, 1, 0, 1, 0, 1], true),
            ("/DeviceRGB", 8, [0, 1, 1, 0, 0, 1], false),
            ("/DeviceCMYK", 8, [0, 1, 0, 1, 0, 1, 0, 1], true),
            (indexed, 8, [0, 255], true),
            (indexed, 4, [0, 15], true),
            (indexed, 8, [0, 1], false),
            (indexed, 8, [255, 0], false),
            (lab, 8, [0, 100, -100, 100, -100, 100], true),
            (ranged, 8, [0, 100, -50, 50, -60, 60], true),
            (ranged, 8, [0, 100, -100, 100, -100, 100], false),
            ("[/ICCBased 6 0 R]", 8, [0, 1, -1, 1, 0, 1], true),
            ("[/ICCBased 6 0 R]", 8, [0, 1, 0, 1, 0, 1], false),
        ]
        for (space, bpc, decode, expected) in cases {
            let file = OptimizeKit.build("q 10 0 0 10 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
                pdf.stream(5, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace \(space) /BitsPerComponent \(bpc) /Filter /FlateDecode", TestPdf.deflate([0, 0, 0]))
                pdf.stream(6, "/N 3 /Range [0 1 -1 1 0 1]", [0])
            })
            let document = try PdfDocument.open(file)

            XCTAssertEqual(ImageKit.defaultDecode(document, try OptimizeKit.image(document).dictionary, decode), expected, "\(space) \(bpc) \(decode)")
        }
    }
}
