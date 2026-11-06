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

    func test_aDecodedPictureThatDoesNotFitIsRefusedNotThrown() throws {
        let session = try EditKit.session("q 1 0 0 rg 0 0 50 50 re f Q")
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
