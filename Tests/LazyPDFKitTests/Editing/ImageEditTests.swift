import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/ImageEditTests.cs: the same cases. EditsReopenInPdfPigAndUndoOneByOne
// counts the pictures with the interpreter where the C# asks PdfPig for them.

final class ImageEditTests: XCTestCase {
    private func open() throws -> (PdfEditSession, PageEditor) {
        try open(try EditPaint.pictures())
    }

    private func open(_ session: PdfEditSession) throws -> (PdfEditSession, PageEditor) {
        (session, try PageEditor(session, 0, EditArialSource()))
    }

    private func first(_ editor: PageEditor) throws -> ImageObject {
        try XCTUnwrap(try editor.objects.compactMap { $0 as? ImageObject }.first)
    }

    private func last(_ editor: PageEditor) throws -> ImageObject {
        try XCTUnwrap(try editor.objects.compactMap { $0 as? ImageObject }.last)
    }

    private func round(_ m: PdfMatrix) -> PdfMatrix {
        PdfMatrix(editRound(m.a, 3), editRound(m.b, 3), editRound(m.c, 3), editRound(m.d, 3), editRound(m.e, 3), editRound(m.f, 3))
    }

    func test_imagesAreInTheModelWithTheirPlacement() throws {
        let (_, editor) = try open()
        let images = try editor.objects.compactMap { $0 as? ImageObject }
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].name, "Im1")
        XCTAssertEqual(images[0].width, 8)
        XCTAssertEqual(images[0].height, 6)
        XCTAssertEqual(images[0].placement, PdfMatrix(100, 0, 0, 50, 100, 600))
        XCTAssertEqual(images[0].bounds, PdfRect(100, 600, 200, 650))
        XCTAssertEqual(images[0].opacity, 1)
    }

    func test_moveWrapsThePaintWithoutTouchingItsCoordinates() throws {
        let (session, editor) = try open()
        let before = EditKit.latin(session)
        let result = try editor.move([try first(editor)], 25, -40)
        XCTAssertTrue(result.done)
        let images = try EditPaint.images(session)
        XCTAssertEqual(images[0].matrix.e, 125, accuracy: 0.0005)
        XCTAssertEqual(images[0].matrix.f, 560, accuracy: 0.0005)
        XCTAssertEqual(images[0].matrix.a, 100, accuracy: 0.0005)
        XCTAssertEqual(images[1].matrix, PdfMatrix(80, 0, 0, 80, 300, 600))
        let after = EditKit.latin(session)
        XCTAssertTrue(after.contains("q 100 0 0 50 100 600 cm"))
        XCTAssertTrue(after.contains("/Im1 Do"))
        XCTAssertNotEqual(before, after)
    }

    func test_resizeRotateAndFlip() throws {
        let (session, editor) = try open()
        XCTAssertTrue(try editor.resize([try first(editor)], PdfRect(100, 600, 300, 700)).done)
        var m = try EditPaint.images(session)[0].matrix
        XCTAssertEqual(round(m), PdfMatrix(200, 0, 0, 100, 100, 600))

        editor.refresh()
        XCTAssertTrue(try editor.rotate([try first(editor)], 90).done)
        m = try EditPaint.images(session)[0].matrix
        XCTAssertEqual(m.a, 0, accuracy: 0.0005)
        XCTAssertEqual(m.b, 200, accuracy: 0.0005)
        XCTAssertEqual(m.c, -100, accuracy: 0.0005)

        editor.refresh()
        let before = try EditPaint.images(session)[0].matrix
        XCTAssertTrue(try editor.flip([try first(editor)], true).done)
        let mirrored = try EditPaint.images(session)[0].matrix
        XCTAssertEqual(-before.a, mirrored.a, accuracy: 0.0005)
        XCTAssertEqual(before.b, mirrored.b, accuracy: 0.0005)
    }

    func test_aCropClipsThePaint() throws {
        let (session, editor) = try open()
        XCTAssertTrue(try editor.crop(try first(editor), PdfRect(120, 610, 170, 640)).done)
        let seen = try EditPaint.images(session)
        XCTAssertEqual(seen[0].clip, PdfRect(120, 610, 170, 640))
        XCTAssertEqual(seen[0].matrix, PdfMatrix(100, 0, 0, 50, 100, 600))
        XCTAssertEqual(seen[1].clip, PdfRect(0, 0, 600, 800))
    }

    func test_aCropOutsideThePictureIsRefused() throws {
        let (session, editor) = try open()
        let result = try editor.crop(try first(editor), PdfRect(400, 10, 450, 40))
        XCTAssertFalse(result.done)
        XCTAssertFalse(session.canUndo)
    }

    func test_replacingKeepsThePlaceAndFitsTheProportions() throws {
        let (session, editor) = try open()
        // The second picture is square at 80 by 80; the JPEG is 8 by 6, so it fills the width and is centred.
        let second = try last(editor)
        let result = try editor.replaceImage(second, try EditPaint.jpeg())
        XCTAssertTrue(result.done)
        let seen = try EditPaint.images(session)
        XCTAssertEqual(seen[1].width, 8)
        XCTAssertEqual(seen[1].height, 6)
        XCTAssertEqual(seen[1].matrix.d, 60, accuracy: 0.0005)
        XCTAssertEqual(seen[1].matrix.a, 80, accuracy: 0.0005)
        XCTAssertEqual(seen[1].matrix.f, 610, accuracy: 0.0005)
        XCTAssertEqual(seen.filter { $0.width == 2 }.count, 0)
    }

    func test_replacingWithAPictureFileNeedsTheCodec() throws {
        let (session, editor) = try open()
        let result = try editor.replaceImage(try first(editor), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertFalse(result.done)
        XCTAssertEqual(try assertSingle(result.skipped).reason, EditingText.noImage)
        XCTAssertFalse(session.canUndo)
    }

    func test_replacingThroughTheCodecEmbedsThePixels() throws {
        let session = try EditPaint.pictures()
        let editor = try PageEditor(session, 0, nil, FakeCodec())
        XCTAssertTrue(try editor.replaceImage(try first(editor), [1, 2, 3], false).done)
        let seen = try EditPaint.images(session)
        XCTAssertEqual(seen[0].width, 2)
        XCTAssertEqual(seen[0].height, 2)
        XCTAssertEqual(seen[0].matrix, PdfMatrix(100, 0, 0, 50, 100, 600))
    }

    private final class FakeCodec: ImageCodec {
        func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }
        func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { [PdfRgbaImage(2, 2, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 9, 9, 9, 128])] }
        func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
    }

    private func assertDone(_ r: ObjectEditResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(r.done, r.skipped.map { $0.reason }.joined(separator: ", "), file: file, line: line)
    }

    func test_deleteOpacityAndOrder() throws {
        let (session, editor) = try open()
        XCTAssertTrue(try editor.setOpacity([try first(editor)], 0.4).done)
        XCTAssertEqual(try EditPaint.images(session)[0].alpha, 0.4, accuracy: 0.0005)
        XCTAssertEqual(try EditPaint.images(session)[1].alpha, 1, accuracy: 0.0005)

        editor.refresh()
        assertDone(try editor.order(try last(editor), .backward))
        XCTAssertEqual(try EditPaint.images(session)[0].width, 2)

        editor.refresh()
        assertDone(try editor.order(try last(editor), .back))
        XCTAssertEqual(try EditPaint.images(session)[0].width, 8)

        editor.refresh()
        assertDone(try editor.order(try first(editor), .front))
        XCTAssertEqual(try EditPaint.images(session)[1].width, 8)

        editor.refresh()
        let again = try editor.order(try last(editor), .forward)
        XCTAssertFalse(again.done)
        XCTAssertEqual(again.skipped[0].reason, EditingText.alreadyThere)

        editor.refresh()
        XCTAssertTrue(try editor.delete([try first(editor)]).done)
        _ = try assertSingle(try EditPaint.images(session))
    }

    func test_extractGivesTheJpegAsStoredAndOtherPicturesAsPng() throws {
        let (_, editor) = try open()
        let jpeg = try XCTUnwrap(try editor.extractImage(try first(editor)))
        XCTAssertEqual(jpeg.fileExtension, "jpg")
        XCTAssertEqual(jpeg.data, try EditPaint.jpeg())
        let png = try XCTUnwrap(try editor.extractImage(try last(editor)))
        XCTAssertEqual(png.fileExtension, "png")
        XCTAssertEqual(Array(png.data[0..<4]), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(png.data[19], 2)
        XCTAssertEqual(png.data[23], 2)
    }

    func test_editsReopenInPdfPigAndUndoOneByOne() throws {
        let (session, editor) = try open()
        _ = try editor.move([try first(editor)], 10, 10)
        editor.refresh()
        _ = try editor.rotate([try first(editor)], 30)
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(try EditPaint.images(session)[0].matrix.e, 110, accuracy: 0.0005)
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(try EditPaint.images(session)[0].matrix.e, 100, accuracy: 0.0005)
        XCTAssertEqual(try EditPaint.images(session).count, 2)
    }
}
