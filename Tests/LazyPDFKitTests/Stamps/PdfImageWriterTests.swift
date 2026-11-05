import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Stamps/PdfImageWriterTests.cs: the same cases. The PdfPig line of
// TranslucentPixelsGetAnSMaskAndReopen (the picture read by a second reader) has no twin; the file is still written and read
// again. PixelsThatDoNotFitTheSizeAreRefused is a precondition here and cannot be caught. TruncatedAndHostileHeadersGiveNull
// is new: the bounds of the marker walk.

final class PdfImageWriterTests: XCTestCase {
    private let jpeg = StampKit.jpeg

    // SOI, an optional Adobe APP14, then a frame header of the given marker and no scan.
    private func header(_ marker: UInt8, _ components: Int, adobe: Bool = false, width: Int = 40, height: Int = 30) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, 0xD8]
        if adobe { bytes += [0xFF, 0xEE, 0, 14, UInt8(ascii: "A"), UInt8(ascii: "d"), UInt8(ascii: "o"), UInt8(ascii: "b"), UInt8(ascii: "e"), 0, 100, 0, 0, 0, 0, 2] }
        let length = 8 + 3 * components
        bytes += [0xFF, marker, 0, UInt8(truncatingIfNeeded: length), 8, UInt8(truncatingIfNeeded: height >> 8), UInt8(truncatingIfNeeded: height),
                  UInt8(truncatingIfNeeded: width >> 8), UInt8(truncatingIfNeeded: width), UInt8(truncatingIfNeeded: components)]
        for i in 0..<components { bytes += [UInt8(truncatingIfNeeded: i + 1), 0x11, 0] }
        bytes += [0xFF, 0xD9]
        return bytes
    }

    private func streamOf(_ document: PdfDocument, _ image: PdfImage) throws -> PdfStream {
        try XCTUnwrap(document.resolve(image.reference) as? PdfStream)
    }

    func test_aPictureWithTooManyPixelsIsRefusedNotAsAMistake() throws {
        let document = try StampKit.doc(1)
        XCTAssertThrowsError(try PdfImageWriter.addRgba(document, 12000, 12000, [])) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, StampsText.pictureTooLarge)
        }
        XCTAssertThrowsError(try PdfImageWriter.addRgba(document, Int.max, 2, [])) { error in
            XCTAssertTrue(error is InvalidOperationException)
        }
    }

    func test_aJpegGoesInAsItIsWithItsSize() throws {
        let document = try StampKit.doc(1)
        let image = try XCTUnwrap(try PdfImageWriter.addJpeg(document, jpeg))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 6)
        let stream = try streamOf(document, image)
        XCTAssertEqual(document.name(stream.dictionary, "Filter"), "DCTDecode")
        XCTAssertEqual(document.name(stream.dictionary, "ColorSpace"), "DeviceRGB")
        XCTAssertEqual(document.integer(stream.dictionary, "Width"), 8)
        XCTAssertEqual(stream.data, jpeg)
    }

    func test_grayAndProgressiveFramesAreRead() throws {
        let document = try StampKit.doc(1)
        let gray = try XCTUnwrap(try PdfImageWriter.addJpeg(document, header(0xC2, 1)))
        XCTAssertEqual(gray.width, 40)
        XCTAssertEqual(gray.height, 30)
        XCTAssertEqual(document.name(try streamOf(document, gray).dictionary, "ColorSpace"), "DeviceGray")
    }

    func test_anAdobeCmykJpegIsInvertedByDecode() throws {
        let document = try StampKit.doc(1)
        let image = try XCTUnwrap(try PdfImageWriter.addJpeg(document, header(0xC0, 4, adobe: true)))
        let dictionary = try streamOf(document, image).dictionary
        XCTAssertEqual(document.name(dictionary, "ColorSpace"), "DeviceCMYK")
        XCTAssertEqual(document.array(dictionary, "Decode")?.items.count, 8)
    }

    func test_whatIsNotAReadableJpegGivesNull() throws {
        let document = try StampKit.doc(1)
        XCTAssertNil(try PdfImageWriter.addJpeg(document, []))
        XCTAssertNil(try PdfImageWriter.addJpeg(document, [0xFF, 0xD8]))
        XCTAssertNil(try PdfImageWriter.addJpeg(document, Array("not a picture at all".utf8)))
        XCTAssertNil(try PdfImageWriter.addJpeg(document, Array(jpeg[..<40])))
        XCTAssertNil(try PdfImageWriter.addJpeg(document, header(0xC0, 2)))
        XCTAssertNil(try PdfImageWriter.addJpeg(document, header(0xC0, 3, width: 0)))
    }

    func test_aRunOfFillBytesBeforeAMarkerIsSkipped() throws {
        let frame = header(0xC0, 3)
        let padded = Array(frame[..<2]) + [0xFF, 0xFF, 0xFF] + Array(frame[2...])
        let found = try XCTUnwrap(PdfImageWriter.tryReadJpegHeader(padded))
        XCTAssertEqual(found.width, 40)
        XCTAssertEqual(found.height, 30)
        XCTAssertEqual(found.components, 3)
    }

    func test_opaquePixelsHaveNoMask() throws {
        let document = try StampKit.doc(1)
        let image = try PdfImageWriter.addRgba(document, 2, 1, [10, 20, 30, 255, 40, 50, 60, 255])
        let stream = try streamOf(document, image)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        XCTAssertNil(stream.dictionary["SMask"])
        XCTAssertEqual(try document.data(stream), [10, 20, 30, 40, 50, 60])
    }

    func test_translucentPixelsGetAnSMaskAndReopen() throws {
        let document = try StampKit.doc(1)
        let image = try PdfImageWriter.addRgba(document, 2, 1, [10, 20, 30, 0, 40, 50, 60, 200])
        let mask = try XCTUnwrap(document.stream(try streamOf(document, image).dictionary, "SMask"))
        XCTAssertEqual(try document.data(mask), [0, 200])
        try PdfStamper(document).addWatermark(WatermarkSpec(image: image))
        let reopened = try PdfDocument.open(try StampKit.rewrite(document))
        XCTAssertEqual(reopened.pages.count, 1)
    }

    func test_truncatedAndHostileHeadersGiveNull() {
        XCTAssertNil(PdfImageWriter.tryReadJpegHeader([0xFF, 0xD8, 0xFF]))
        XCTAssertNil(PdfImageWriter.tryReadJpegHeader([0xFF, 0xD8, 0xFF, 0xC0]))
        XCTAssertNil(PdfImageWriter.tryReadJpegHeader([0xFF, 0xD8, 0xFF, 0xC0, 0xFF, 0xFF]))
        XCTAssertNil(PdfImageWriter.tryReadJpegHeader([0xFF, 0xD8, 0xFF, 0xC0, 0, 7, 8, 0, 1, 0, 1]))
        XCTAssertNil(PdfImageWriter.tryReadJpegHeader([0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 0, 0]))
        XCTAssertNil(PdfImageWriter.tryReadJpegHeader([0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF, 0, 0]))
    }
}
