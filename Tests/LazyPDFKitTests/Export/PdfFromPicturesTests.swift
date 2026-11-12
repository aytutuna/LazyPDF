import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/PdfFromPicturesTests.cs: the same cases, except TheFileReopensInPdfPig, whose
// assertions are all PdfPig's and have no twin; the files are read again by this engine in every other test.

final class PdfFromPicturesTests: XCTestCase {
    private let codec = ExportFakeCodec()

    private func reopen(_ made: PicturesPdf, _ page: Int = 0) throws -> (document: PdfDocument, images: [ImageInfo]) {
        let document = try PdfDocument.open(made.bytes)
        let recorder = Recorder()
        ContentInterpreter(document).run(document.pages[page], recorder)
        return (document, recorder.images)
    }

    private func mediaBox(_ made: PicturesPdf, _ page: Int = 0) throws -> PdfRect {
        try PdfDocument.open(made.bytes).pages[page].mediaBox
    }

    private func jpeg(_ dpi: Int = 0) -> [UInt8] {
        var bytes = ExportKit.jpeg
        if dpi > 0 { (bytes[13], bytes[14], bytes[15], bytes[16], bytes[17]) = (1, UInt8(truncatingIfNeeded: dpi >> 8), UInt8(truncatingIfNeeded: dpi), UInt8(truncatingIfNeeded: dpi >> 8), UInt8(truncatingIfNeeded: dpi)) }
        return bytes
    }

    func test_aJpegGoesInWithoutBeingEncodedAgain() throws {
        let made = try PdfFromPictures.create([jpeg()], codec)
        let (document, images) = try reopen(made)
        XCTAssertEqual(images.count, 1)
        let image = images[0]
        XCTAssertEqual(document.rawData(try XCTUnwrap(image.stream)), ExportKit.jpeg)
        XCTAssertEqual((image.dictionary["Filter"] as? PdfName)?.value, "DCTDecode")
        XCTAssertTrue(codec.decoded.isEmpty)
    }

    func test_thePictureIsCentredAtItsNaturalSizeOnA4() throws {
        let made = try PdfFromPictures.create([jpeg(300)], codec, PdfPageSetup(orientation: .portrait, margin: 0))
        let (document, images) = try reopen(made)
        let page = document.pages[0].mediaBox
        XCTAssertEqual(page.width, 595.276)
        XCTAssertEqual(page.height, 841.89)
        let w = 8 * 72 / 300.0, h = 6 * 72 / 300.0
        let box = images[0].bounds
        XCTAssertEqual(box.width, w, accuracy: 1e-4)
        XCTAssertEqual(box.height, h, accuracy: 1e-4)
        XCTAssertEqual(box.left, (595.276 - w) / 2, accuracy: 1e-4)
        XCTAssertEqual(box.bottom, (841.89 - h) / 2, accuracy: 1e-4)
    }

    func test_customPaperIsClamped() throws {
        for (w, h, ew, eh) in [(200.0, 300.0, 200.0, 300.0), (1, 99999, 3, 14400), (.nan, 50, 3, 50)] {
            let setup = PdfPageSetup(paper: .custom, orientation: .portrait, margin: 0, customWidth: w, customHeight: h)
            let (document, _) = try reopen(PdfFromPictures.create([ExportFakeCodec.picture(2, 2)], codec, setup))
            let page = document.pages[0].mediaBox
            XCTAssertEqual([page.width, page.height], [ew, eh])
        }
    }

    func test_aBigPictureShrinksIntoTheMargin() throws {
        let file = ExportFakeCodec.picture(255, 20)
        let made = try PdfFromPictures.create([file], codec, PdfPageSetup(paper: .letter, orientation: .portrait, margin: 250))
        let (document, images) = try reopen(made)
        let page = document.pages[0].mediaBox
        XCTAssertEqual([page.width, page.height], [612, 792])
        XCTAssertEqual(images[0].bounds.width, 112, accuracy: 1e-6)
        XCTAssertEqual(images[0].bounds.height, 112.0 * 20 / 255, accuracy: 1e-6)
        XCTAssertEqual((images[0].bounds.left + images[0].bounds.right) / 2, 306, accuracy: 1e-6)
    }

    func test_fitToPictureSizesThePageToThePictureAndMargin() throws {
        let made = try PdfFromPictures.create([ExportFakeCodec.picture(96, 48)], codec, PdfPageSetup(paper: .picture, margin: 10))
        let page = try mediaBox(made)
        XCTAssertEqual([page.width, page.height], [92.0, 56.0])
    }

    func test_orientationFollowsThePictureOrIsForced() throws {
        let wide = ExportFakeCodec.picture(40, 10)
        let auto = try mediaBox(PdfFromPictures.create([wide], codec))
        let portrait = try mediaBox(PdfFromPictures.create([wide], codec, PdfPageSetup(orientation: .portrait)))
        let landscape = try mediaBox(PdfFromPictures.create([ExportFakeCodec.picture(10, 40)], codec, PdfPageSetup(orientation: .landscape)))
        XCTAssertGreaterThan(auto.width, auto.height)
        XCTAssertLessThan(portrait.width, portrait.height)
        XCTAssertGreaterThan(landscape.width, landscape.height)
    }

    func test_aWideCustomPaperIsTurnedLikeTheNamedOnes() throws {
        let wide = ExportFakeCodec.picture(40, 10), tall = ExportFakeCodec.picture(10, 40)
        func box(_ picture: [UInt8], _ orientation: PdfOrientation) throws -> [Double] {
            let setup = PdfPageSetup(paper: .custom, orientation: orientation, margin: 0, customWidth: 1000, customHeight: 500)
            let page = try mediaBox(PdfFromPictures.create([picture], codec, setup))
            return [page.width, page.height]
        }
        XCTAssertEqual(try box(wide, .landscape), [1000, 500])
        XCTAssertEqual(try box(wide, .auto), [1000, 500])
        XCTAssertEqual(try box(tall, .auto), [500, 1000])
        XCTAssertEqual(try box(wide, .portrait), [500, 1000])
    }

    func test_onePageForEachFileInOrderAndUnreadableFilesAreReported() throws {
        let made = try PdfFromPictures.create([ExportFakeCodec.picture(4, 4, 10), [1, 2, 3], jpeg(), ExportFakeCodec.picture(4, 4, 200)], codec)
        XCTAssertEqual(made.pages, 3)
        XCTAssertEqual(made.unreadable, [1])
        let reopened = try PdfDocument.open(made.bytes)
        XCTAssertEqual(reopened.pages.count, 3)
        let xobjects = try XCTUnwrap(reopened.resolve(reopened.pages[1].resources?["XObject"]) as? PdfDictionary)
        let stream = try XCTUnwrap(reopened.resolve(xobjects["Im1"]) as? PdfStream)
        XCTAssertEqual(reopened.rawData(stream), ExportKit.jpeg)
    }

    func test_aFrameTooBigToDecodeIsLeftOutAndCounted() throws {
        let made = try PdfFromPictures.create([[UInt8(ascii: "B"), 2]], codec)
        XCTAssertEqual(made.pages, 2)
        XCTAssertEqual(made.skippedFrames, 1)
        XCTAssertTrue(made.unreadable.isEmpty)
    }

    func test_aFileOfOnlyTooBigFramesIsCountedOnlyAsSkipped() throws {
        let made = try PdfFromPictures.create([ExportFakeCodec.picture(4, 4), [UInt8(ascii: "B"), 0]], codec)
        XCTAssertEqual(made.pages, 1)
        XCTAssertEqual(made.skippedFrames, 1)
        XCTAssertTrue(made.unreadable.isEmpty)
    }

    func test_aFileOnlyTheCodecKnowsIsDecodedAndKeptLossless() throws {
        let made = try PdfFromPictures.create([ExportFakeCodec.picture(3, 2, 77)], codec)
        let (document, images) = try reopen(made)
        let samples = try document.data(XCTUnwrap(images[0].stream))
        XCTAssertEqual(samples, [UInt8](repeating: 77, count: 18))
    }

    func test_nothingReadableIsAnError() {
        XCTAssertThrowsError(try PdfFromPictures.create([[1, 2, 3], []], codec)) { error in
            XCTAssertTrue(error is ArgumentException)
            XCTAssertTrue("\(error)".contains(ExportText.noUsablePicture))
        }
        XCTAssertThrowsError(try PdfFromPictures.create([], codec)) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try PdfFromPictures.create([jpeg()], codec, PdfPageSetup(margin: -1))) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_aBrokenJpegFallsBackToTheCodec() throws {
        let broken: [UInt8] = [0xFF, 0xD8, 0xFF, 0xD9]
        let made = try PdfFromPictures.create([broken, jpeg()], codec)
        XCTAssertEqual(made.pages, 1)
        XCTAssertEqual(made.unreadable, [0])
    }

    // The sample JPEG with an Exif block after its JFIF header that carries the given orientation.
    private func oriented(_ orientation: Int, _ xDpi: Int = 0, _ yDpi: Int = 0) -> [UInt8] {
        var jpeg = self.jpeg()
        if xDpi > 0 {
            (jpeg[13], jpeg[14], jpeg[15], jpeg[16], jpeg[17]) = (1, UInt8(truncatingIfNeeded: xDpi >> 8), UInt8(truncatingIfNeeded: xDpi), UInt8(truncatingIfNeeded: yDpi >> 8), UInt8(truncatingIfNeeded: yDpi))
        }
        var exif: [UInt8] = [0xFF, 0xE1, 0, 34]
        exif += Array("Exif".utf8)
        exif += [0, 0]
        exif += Array("MM".utf8)
        exif += [0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0]
        exif += [UInt8(orientation), 0, 0, 0, 0, 0, 0]
        let at = 4 + (Int(jpeg[4]) << 8 | Int(jpeg[5]))
        return Array(jpeg[..<at]) + exif + Array(jpeg[at...])
    }

    func test_exifOrientationTurnsThePictureAndChoosesThePageShape() throws {
        let file = oriented(6)
        let made = try PdfFromPictures.create([file], codec, PdfPageSetup(margin: 0))
        let (document, images) = try reopen(made)
        let page = document.pages[0].mediaBox
        XCTAssertGreaterThan(page.height, page.width)
        let m = images[0].matrix
        XCTAssertEqual(m.a, 0, accuracy: 1e-6)
        XCTAssertEqual(m.d, 0, accuracy: 1e-6)
        XCTAssertEqual(m.c, 6 * 72 / 96.0, accuracy: 1e-6)
        XCTAssertEqual(m.b, -8 * 72 / 96.0, accuracy: 1e-6)
        XCTAssertEqual(document.rawData(try XCTUnwrap(images[0].stream)), file)
    }

    func test_aMirroredOrientationFlipsTheMatrixAndFitToPictureSwapsSides() throws {
        let made = try PdfFromPictures.create([oriented(2), oriented(8)], codec, PdfPageSetup(paper: .picture, margin: 0))
        let (document, images) = try reopen(made)
        XCTAssertLessThan(images[0].matrix.a, 0)
        let turned = document.pages[1].mediaBox
        XCTAssertEqual(turned.width, 6 * 72 / 96.0, accuracy: 1e-6)
        XCTAssertEqual(turned.height, 8 * 72 / 96.0, accuracy: 1e-6)
    }

    func test_densityOfBothAxesIsUsed() throws {
        let made = try PdfFromPictures.create([oriented(1, 200, 100)], codec, PdfPageSetup(margin: 0))
        let box = try reopen(made).images[0].bounds
        XCTAssertEqual(box.width, 8 * 72 / 200.0, accuracy: 1e-4)
        XCTAssertEqual(box.height, 6 * 72 / 100.0, accuracy: 1e-4)
    }

    func test_aDecodedFrameIsPlacedAtTheDensityItCarries() throws {
        let cases: [(Int, Int, Double, Double)] = [(300, 300, 24, 24), (72, 72, 100, 100), (300, 150, 24, 48), (0, 0, 75, 75), (5000, 5000, 75, 75), (300, 5000, 75, 75)]
        for (dpiX, dpiY, width, height) in cases {
            let made = try PdfFromPictures.create([ExportFakeCodec.picture(100, 100, 128, dpiX: dpiX, dpiY: dpiY)], codec, PdfPageSetup(paper: .picture, margin: 0))
            let box = try reopen(made).images[0].bounds
            XCTAssertEqual(box.width, width, accuracy: 1e-4)
            XCTAssertEqual(box.height, height, accuracy: 1e-4)
        }
    }

    func test_aMarginThatLeavesNoRoomIsRefused() {
        for margin in [300.0, 297.638] {
            XCTAssertThrowsError(try PdfFromPictures.create([jpeg()], codec, PdfPageSetup(margin: margin)), "margin \(margin)") { XCTAssertTrue($0 is ArgumentException) }
        }
    }

    func test_aCancelledTokenStopsTheMakingOfThePdf() async throws {
        let codec = codec
        let file = jpeg()
        let task = Task { () -> PicturesPdf in
            while !Task.isCancelled { await Task.yield() }
            return try PdfFromPictures.create([file], codec)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_aCancelDuringTheFirstDecodeStopsBeforeTheThirdFile() async throws {
        let codec = CancellingCodec(codec)
        let file = ExportFakeCodec.picture(4, 4)
        let task = Task { try PdfFromPictures.create([file, file, file], codec) }
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(codec.files, 1)
    }

    private final class CancellingCodec: ImageCodec {
        private let inner: ImageCodec
        private(set) var files = 0

        init(_ inner: ImageCodec) { self.inner = inner }

        func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }

        func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? {
            files += 1
            withUnsafeCurrentTask { $0?.cancel() }
            return inner.decodeFile(file)
        }

        func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
    }}
