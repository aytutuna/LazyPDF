import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/AddImageTests.cs: the same cases. A picture added to a page: centred in the
// box it was given and upright on the page as it is shown.

final class AddImageTests: XCTestCase {
    private final class SquareCodec: ImageCodec {
        func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }
        func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { file.isEmpty ? nil : [PdfRgbaImage(2, 2, [UInt8](repeating: 0, count: 16))] }
        func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
    }

    private final class HugeCodec: ImageCodec {
        func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }
        func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { [PdfRgbaImage(12000, 12000, [UInt8](repeating: 0, count: 16))] }
        func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
    }

    // Decodes any file as 4 by 2 gray pixels 10 to 17, row by row.
    private final class RowsCodec: ImageCodec {
        func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }
        func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? {
            var rgba = [UInt8]()
            for i in 0..<8 { rgba += [UInt8(10 + i), UInt8(10 + i), UInt8(10 + i), 255] }
            return [PdfRgbaImage(4, 2, rgba)]
        }
        func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
    }

    // The sample JPEG with an Exif block after its JFIF header that carries the given orientation.
    private func oriented(_ orientation: Int) -> [UInt8] {
        let jpeg = ExportKit.jpeg
        var exif: [UInt8] = [0xFF, 0xE1, 0, 34]
        exif += Array("Exif".utf8)
        exif += [0, 0]
        exif += Array("MM".utf8)
        exif += [0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0]
        exif += [UInt8(orientation), 0, 0, 0, 0, 0, 0]
        let at = 4 + (Int(jpeg[4]) << 8 | Int(jpeg[5]))
        return Array(jpeg[..<at]) + exif + Array(jpeg[at...])
    }

    private func added(_ orientation: Int) throws -> (image: PdfImage, gray: [UInt8]) {
        let document = try ExportKit.open("")
        let image = try XCTUnwrap(PdfImageWriter.addPicture(document, oriented(orientation), RowsCodec()))
        let stream = try XCTUnwrap(document.resolve(image.reference) as? PdfStream)
        let samples = try document.data(stream)
        return (image, samples.enumerated().filter { $0.offset % 3 == 0 }.map { $0.element })
    }

    func test_aJpegTurnedBySixIsStoredUprightAndSwapsItsSides() throws {
        let (image, gray) = try added(6)

        XCTAssertEqual([image.width, image.height], [2, 4])
        XCTAssertEqual(gray, [14, 10, 15, 11, 16, 12, 17, 13])
    }

    func test_aJpegTurnedByThreeKeepsItsSizeAndReversesRowsAndColumns() throws {
        let (image, gray) = try added(3)

        XCTAssertEqual([image.width, image.height], [4, 2])
        XCTAssertEqual(gray, [17, 16, 15, 14, 13, 12, 11, 10])
    }

    func test_aJpegWithoutATurnKeepsItsBytes() throws {
        let document = try ExportKit.open("")
        let file = oriented(1)

        let image = try XCTUnwrap(PdfImageWriter.addPicture(document, file, RowsCodec()))

        let stream = try XCTUnwrap(document.resolve(image.reference) as? PdfStream)
        XCTAssertEqual((stream.dictionary["Filter"] as? PdfName)?.value, "DCTDecode")
        XCTAssertEqual(document.rawData(stream), file)
    }

    func test_aTurnedJpegOnAPageIsAddedUpright() throws {
        let session = try EditKit.session("q 1 0 0 rg 0 0 50 50 re f Q")
        let editor = try PageEditor(session, 0, nil, RowsCodec())

        XCTAssertTrue(try editor.addImage(PdfRect(100, 500, 300, 600), oriented(8)).done)

        let image = try assertSingle(try EditPaint.images(session))
        XCTAssertEqual([image.width, image.height], [2, 4])
    }

    func test_aDecodedPictureThatDoesNotFitIsRefusedNotThrown() throws {        let session = try EditKit.session("q 1 0 0 rg 0 0 50 50 re f Q")
        let editor = try PageEditor(session, 0, nil, HugeCodec())

        let result = try editor.addImage(PdfRect(100, 500, 300, 600), [1])

        XCTAssertFalse(result.done)
        XCTAssertTrue(try EditPaint.images(session).isEmpty)
    }

    func test_thePictureKeepsItsShapeAndSitsInTheMiddleOfTheBox() throws {
        let session = try EditKit.session("q 1 0 0 rg 0 0 50 50 re f Q")
        let editor = try PageEditor(session, 0, nil, SquareCodec())

        let result = try editor.addImage(PdfRect(100, 500, 300, 600), [1])

        XCTAssertTrue(result.done)
        let image = try assertSingle(try EditPaint.images(session))
        XCTAssertEqual(image.matrix, PdfMatrix(100, 0, 0, 100, 150, 500))
    }

    func test_onATurnedPageThePictureIsStillUprightInTheBox() throws {
        let session = try EditKit.session("q 1 0 0 rg 0 0 50 50 re f Q", "/Rotate 90")
        let editor = try PageEditor(session, 0, nil, SquareCodec())

        XCTAssertTrue(try editor.addImage(PdfRect(100, 500, 300, 600), [1]).done)

        let bounds = try assertSingle(try editor.objects.compactMap { $0 as? ImageObject }).bounds
        XCTAssertEqual(bounds.width, 100, accuracy: 0.05)
        XCTAssertEqual(bounds.height, 100, accuracy: 0.05)
        XCTAssertEqual((bounds.left + bounds.right) / 2, 200, accuracy: 0.05)
        XCTAssertEqual((bounds.bottom + bounds.top) / 2, 550, accuracy: 0.05)
    }

    func test_bytesNoCodecReadAreRefusedAndNothingIsCommitted() throws {
        let session = try EditKit.session("q 1 0 0 rg 0 0 50 50 re f Q")
        let editor = try PageEditor(session, 0, nil, SquareCodec())

        let result = try editor.addImage(PdfRect(100, 500, 300, 600), [])

        XCTAssertFalse(result.done)
        XCTAssertEqual(result.skipped[0].reason, EditingText.noImage)
        XCTAssertFalse(session.canUndo)
    }

    func test_anEmptyBoxIsRefused() throws {
        let session = try EditKit.session("q 1 0 0 rg 0 0 50 50 re f Q")

        let result = try PageEditor(session, 0, nil, SquareCodec()).addImage(PdfRect(100, 500, 100, 600), [1])

        XCTAssertFalse(result.done)
        XCTAssertFalse(session.canUndo)
    }
}
