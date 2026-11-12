import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactImageTests.cs: the same cases.

final class RedactImageTests: XCTestCase {
    private let place = "q 160 0 0 160 100 100 cm /Im1 Do Q"

    // Pixel (x, y) holds 1 + y * 8 + x, never zero, so a zeroed pixel is a removed one.
    private func gradient() -> [UInt8] { (0..<64).map { UInt8($0 + 1) } }

    private func withImage(_ entries: String, _ data: [UInt8], _ content: String? = nil, more: ((TestPdf) -> Void)? = nil) throws -> PdfDocument {
        try RedactionKit.page(content ?? place, "/XObject <</Im1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 8 /Height 8 \(entries)", data)
            more?(pdf)
        }
    }

    private func samples(_ document: PdfDocument, _ page: Int = 0) throws -> [UInt8] {
        let images = RedactionKit.images(document, page)
        XCTAssertEqual(images.count, 1)
        return try document.data(try XCTUnwrap(images.first?.stream))
    }

    // The top left 2 by 2 pixels: the image covers 100..260 on both axes, a pixel is 20 points.
    private func topLeft(_ page: Int = 0) -> RedactionMark { RedactionMark.fromRect(page, PdfRect(100, 220, 140, 260)) }

    private func imageStreams(_ document: PdfDocument) -> [PdfStream] {
        document.objectNumbers.compactMap { document.get($0) as? PdfStream }.filter { document.name($0.dictionary, "Subtype") == "Image" }
    }

    func test_pixelsUnderTheMarkAreZeroInTheSamplesAndTheOthersStay() throws {
        let document = try withImage("/ColorSpace /DeviceGray /BitsPerComponent 8", gradient())
        let result = try PdfRedactor(document).apply([topLeft()])
        let output = try RedactionKit.open(result)
        var expected = gradient()
        for i in [0, 1, 8, 9] { expected[i] = 0 }
        XCTAssertEqual(try samples(output), expected)
        XCTAssertEqual(result.report.images, 1)
    }

    func test_theCoveredPixelsAreNotInTheFileAnywhere() throws {
        let data = gradient()
        let document = try withImage("/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate(data))
        let result = try PdfRedactor(document).apply([topLeft()])
        let output = try RedactionKit.open(result)
        let streams = imageStreams(output)
        XCTAssertEqual(streams.count, 1)
        let decoded = try output.data(streams[0])
        XCTAssertNotEqual(decoded, data)
        XCTAssertEqual(Array(decoded[2..<8]), Array(data[2..<8]))
    }

    func test_fourBitSamplesAreClearedByTheBit() throws {
        let document = try withImage("/ColorSpace /DeviceGray /BitsPerComponent 4", [UInt8](repeating: 0xFF, count: 32))
        let result = try PdfRedactor(document).apply([topLeft()])
        let output = try RedactionKit.open(result)
        let found = try samples(output)
        XCTAssertEqual(found[0], 0)
        XCTAssertEqual(found[4], 0)
        XCTAssertEqual(found[1], 0xFF)
        XCTAssertEqual(found[8], 0xFF)
    }

    func test_imageMaskBitsAreCleared() throws {
        let document = try withImage("/ImageMask true /BitsPerComponent 1", [UInt8](repeating: 0xFF, count: 8))
        let result = try PdfRedactor(document).apply([topLeft()])
        let output = try RedactionKit.open(result)
        let found = try samples(output)
        XCTAssertEqual(found[0], 0x3F)
        XCTAssertEqual(found[1], 0x3F)
        XCTAssertEqual(found[2], 0xFF)
    }

    func test_softMaskIsCutToo() throws {
        let document = try withImage("/ColorSpace /DeviceGray /BitsPerComponent 8 /SMask 7 0 R", gradient(), more: { pdf in
            pdf.stream(7, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8", self.gradient())
        })
        let result = try PdfRedactor(document).apply([topLeft()])
        let output = try RedactionKit.open(result)
        let image = try XCTUnwrap(RedactionKit.images(output).first?.stream)
        let mask = try output.data(try XCTUnwrap(output.stream(image.dictionary, "SMask")))
        XCTAssertEqual(mask[0], 0)
        XCTAssertEqual(mask[9], 0)
        XCTAssertEqual(mask[2], 3)
        XCTAssertEqual(imageStreams(output).count, 2)
    }

    func test_sharedImageGetsAPrivateCopyForTheMarkedUse() throws {
        let data = gradient()
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources 7 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources 7 0 R>>")
        pdf.stream(5, "", place)
        pdf.stream(6, "", place + " " + place.replacingOccurrences(of: "100 100", with: "300 300"))
        pdf.obj(7, "<</XObject <</Im1 8 0 R>>>>")
        pdf.stream(8, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8", data)
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfRedactor(document).apply([topLeft(0)])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(try samples(output, 0)[0], 0)
        let second = RedactionKit.images(output, 1)
        XCTAssertEqual(second.count, 2)
        for i in second { XCTAssertEqual(try output.data(try XCTUnwrap(i.stream)), data) }
        XCTAssertTrue(RedactionKit.images(output, 0).first?.stream !== second[0].stream)
    }

    private func jpegDocument() throws -> PdfDocument {
        let jpeg = [UInt8](Data(base64Encoded: ExportKit.sampleJpeg) ?? Data())
        return try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg)
        }
    }

    func test_jpegGoesThroughTheCodecAndComesBackAsFlate() throws {
        let jpeg = [UInt8](Data(base64Encoded: ExportKit.sampleJpeg) ?? Data())
        let pixel: [UInt8] = [200, 100, 50, 255]
        let rgba = (0..<(8 * 6)).flatMap { _ in pixel }
        let document = try jpegDocument()
        let result = try PdfRedactor(document, nil, FakeCodec(PdfRgbaImage(8, 6, rgba))).apply([topLeft()])
        let output = try RedactionKit.open(result)
        let image = try XCTUnwrap(RedactionKit.images(output).first?.stream)
        XCTAssertEqual(output.name(image.dictionary, "Filter"), "FlateDecode")
        let found = try output.data(image)
        XCTAssertEqual(found.count, 8 * 6 * 3)
        XCTAssertEqual(Array(found[0..<3]), [0, 0, 0])
        XCTAssertEqual(Array(found[(5 * 3)..<(6 * 3)]), [200, 100, 50])
        let head = Array(jpeg.prefix(24))
        for number in output.objectNumbers {
            if let stream = output.get(number) as? PdfStream { XCTAssertNil(output.rawData(stream).indexOf(head)) }
        }
    }

    func test_jpegWithoutACodecIsRemoved() throws {
        let document = try jpegDocument()
        let result = try PdfRedactor(document).apply([topLeft()])
        let output = try RedactionKit.open(result)
        XCTAssertTrue(RedactionKit.images(output).isEmpty)
        XCTAssertTrue(imageStreams(output).isEmpty)
        XCTAssertEqual(result.report.images, 1)
    }

    func test_failedDecodeRemovesTheImage() throws {
        let document = try jpegDocument()
        let result = try PdfRedactor(document, nil, FakeCodec(nil)).apply([topLeft()])
        let output = try RedactionKit.open(result)
        XCTAssertTrue(RedactionKit.images(output).isEmpty)
        XCTAssertTrue(imageStreams(output).isEmpty)
    }

    func test_pictureThatCannotBeDecodedIsRemoved() throws {
        for filter in ["JBIG2Decode", "JPXDecode"] {
            for codec in [false, true] {
                let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in
                    pdf.stream(6, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /\(filter)", [1, 2, 3, 4, 5, 6])
                }
                let result = try PdfRedactor(document, nil, codec ? FakeCodec(nil) : nil).apply([topLeft()])
                let output = try RedactionKit.open(result)
                XCTAssertTrue(RedactionKit.images(output).isEmpty, filter)
                XCTAssertTrue(imageStreams(output).isEmpty, filter)
                XCTAssertEqual(result.report.images, 1, filter)
            }
        }
    }

    func test_imageOutsideTheMarkIsLeftAlone() throws {
        let data = gradient()
        let document = try withImage("/ColorSpace /DeviceGray /BitsPerComponent 8", data)
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(300, 300, 400, 400))])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(try samples(output), data)
        XCTAssertEqual(result.report.images, 0)
    }

    func test_inlineImageUnderTheMarkIsRemoved() throws {
        let content = "q 160 0 0 160 100 100 cm BI /W 2 /H 2 /CS /G /BPC 8 ID \u{01}\u{02}\u{03}\u{04}\nEI Q BT /F1 12 Tf 50 50 Td (kept) Tj ET"
        let document = try RedactionKit.page(content)
        XCTAssertEqual(RedactionKit.images(document).count, 1)
        let result = try PdfRedactor(document).apply([topLeft()])
        let output = try RedactionKit.open(result)
        XCTAssertTrue(RedactionKit.images(output).isEmpty)
        XCTAssertEqual(RedactionKit.text(output), "kept")
    }
}
