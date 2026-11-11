import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/sign/SignatureArtTests.cs and SavedSignaturesTests.cs: the picture of a signature typed,
// drawn or taken from a photo, and the ones kept for reuse. Typing draws with the system's text and needs Apple's frameworks, so
// its test is wrapped; the codec of the photo tests is a stand-in that hands back the picture it was given.

/// Reads any file as the picture it was made with.
final class SignaturePictureCodec: ImageCodec {
    var frame: PdfRgbaImage?

    init(_ frame: PdfRgbaImage?) {
        self.frame = frame
    }

    func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }
    func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { frame.map { [$0] } }
    func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
}

final class SignatureArtTests: XCTestCase {
    private func blank(_ width: Int, _ height: Int) -> PdfRgbaImage {
        PdfRgbaImage(width, height, [UInt8](repeating: 0, count: width * height * 4))
    }

    private func opaque(_ image: PdfRgbaImage) -> Int {
        (0..<image.width * image.height).filter { image.rgba[$0 * 4 + 3] > 128 }.count
    }

    func test_aStrokeIsDrawnBlackAndCutToItsSize() throws {
        var strokes = SignatureStrokes()
        strokes.begin(ViewPoint(10, 10))
        strokes.extend(ViewPoint(110, 40))

        let image = try XCTUnwrap(SignatureArt.drawn(strokes))

        XCTAssertTrue((300...400).contains(image.width), "\(image.width)")
        XCTAssertTrue((80...200).contains(image.height), "\(image.height)")
        XCTAssertGreaterThan(opaque(image), 100)
        for i in 0..<image.width * image.height where image.rgba[i * 4 + 3] > 128 {
            XCTAssertLessThan(image.rgba[i * 4], 10)
        }
    }

    func test_noStrokesIsNoSignature() {
        XCTAssertNil(SignatureArt.drawn(SignatureStrokes()))
    }

    func test_aSingleTouchIsADot() throws {
        var strokes = SignatureStrokes()
        strokes.begin(ViewPoint(50, 50))

        let image = try XCTUnwrap(SignatureArt.drawn(strokes))

        XCTAssertGreaterThan(opaque(image), 10)
        XCTAssertLessThan(image.width, 40)
    }

    func test_theStrokesKeepTheirOrderAndTheBoundsHoldThePen() {
        var strokes = SignatureStrokes()
        strokes.begin(ViewPoint(10, 20))
        strokes.extend(ViewPoint(10, 20))
        strokes.extend(ViewPoint(30, 25))
        strokes.begin(ViewPoint(5, 40))

        XCTAssertEqual(strokes.strokes.count, 2)
        XCTAssertEqual(strokes.strokes[0], [ViewPoint(10, 20), ViewPoint(30, 25)])
        XCTAssertEqual(strokes.bounds, ViewRect(4, 19, 27, 22))
        strokes.removeLast()
        XCTAssertEqual(strokes.strokes.count, 1)
        strokes.clear()
        XCTAssertTrue(strokes.isEmpty)
        XCTAssertNil(strokes.bounds)
    }

    func test_paperGoesClearAndInkStays() {
        let pixels: [UInt8] = [255, 255, 255, 255, 20, 20, 20, 255, 200, 200, 200, 255]

        let cleared = SignatureArt.paperToClear(PdfRgbaImage(3, 1, pixels))

        XCTAssertEqual(cleared.rgba[3], 0)
        XCTAssertEqual(cleared.rgba[7], 255)
        XCTAssertTrue((1...254).contains(cleared.rgba[11]))
    }

    func test_trimKeepsTheInkAndAThinBorder() {
        var image = blank(40, 30)
        var pixels = image.rgba
        pixels[(15 * 40 + 20) * 4 + 3] = 255
        image = PdfRgbaImage(40, 30, pixels)

        let trimmed = SignatureArt.trim(image)

        XCTAssertEqual(trimmed.width, 9)
        XCTAssertEqual(trimmed.height, 9)
        XCTAssertEqual(trimmed.rgba[(4 * 9 + 4) * 4 + 3], 255)
    }

    func test_anEmptyPictureIsLeftAlone() {
        let image = blank(5, 5)

        let same = SignatureArt.trim(image)

        XCTAssertEqual(same.width, 5)
        XCTAssertEqual(same.rgba, image.rgba)
    }

    func test_aPhotoOfInkOnPaperBecomesInkOnClear() throws {
        var pixels = [UInt8](repeating: 250, count: 30 * 20 * 4)
        for x in 5..<25 {
            let at = (10 * 30 + x) * 4
            pixels[at] = 10
            pixels[at + 1] = 10
            pixels[at + 2] = 10
        }

        let made = try XCTUnwrap(SignatureArt.fromFile([1], SignaturePictureCodec(PdfRgbaImage(30, 20, pixels))))

        XCTAssertTrue((20...30).contains(made.width), "\(made.width)")
        XCTAssertTrue(made.rgba[3] < 8 || made.rgba[3] == 255)
        XCTAssertTrue((15...30 * 20).contains(opaque(made)))
        XCTAssertLessThan(opaque(made), made.width * made.height)
    }

    func test_aFileThatIsNotAPictureGivesNothing() {
        XCTAssertNil(SignatureArt.fromFile([1, 2, 3, 4], SignaturePictureCodec(nil)))
    }

    func test_aPhotoIsTurnedTheWayItsCameraSaidWhenItWasTaken() throws {
        let black = PdfRgbaImage(24, 8, (0..<24 * 8).flatMap { _ in [UInt8(0), 0, 0, 255] })
        let cases: [(Int, Int, Int)] = [(1, 24, 8), (3, 24, 8), (6, 8, 24), (8, 8, 24), (5, 8, 24)]
        for (orientation, width, height) in cases {
            let image = try XCTUnwrap(SignatureArt.fromFile([1], SignaturePictureCodec(black), orientation: orientation))

            XCTAssertEqual([image.width, image.height], [width, height], "orientation \(orientation)")
        }
    }

    private func jpeg(orientation: Int, little: Bool = false) -> [UInt8] {
        func short(_ v: Int) -> [UInt8] { little ? [UInt8(v & 255), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 255)] }
        var tiff: [UInt8] = little ? [0x49, 0x49, 42, 0, 8, 0, 0, 0] : [0x4D, 0x4D, 0, 42, 0, 0, 0, 8]
        tiff += short(1)
        tiff += short(0x0112)
        tiff += short(3)
        tiff += little ? [1, 0, 0, 0] : [0, 0, 0, 1]
        tiff += short(orientation)
        tiff += [0, 0, 0, 0, 0, 0]
        let body: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0, 0] + tiff
        let length = body.count + 2
        return [0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 255)] + body + [0xFF, 0xD9]
    }

    func test_theOrientationIsReadFromTheExifOfAJpegInEitherByteOrder() {
        XCTAssertEqual(SignatureArt.exifOrientation(jpeg(orientation: 6)), 6)
        XCTAssertEqual(SignatureArt.exifOrientation(jpeg(orientation: 8, little: true)), 8)
        XCTAssertEqual(SignatureArt.exifOrientation(jpeg(orientation: 9)), 8)
    }

    func test_aFileWithoutExifOrTruncatedIsTheUsualOrientation() {
        XCTAssertEqual(SignatureArt.exifOrientation([0xFF, 0xD8, 0xFF, 0xD9]), 1)
        XCTAssertEqual(SignatureArt.exifOrientation([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]), 1)
        XCTAssertEqual(SignatureArt.exifOrientation(Array(jpeg(orientation: 6).prefix(20))), 1)
        XCTAssertEqual(SignatureArt.exifOrientation([]), 1)
    }

    func test_aSidewaysJpegIsTurnedBeforeItIsUsed() throws {
        final class Codec: ImageCodec {
            func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }
            func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { [PdfRgbaImage(24, 8, [UInt8](repeating: 0, count: 24 * 8 * 4))] }
            func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [UInt8(image.width), UInt8(image.height)] }
        }

        XCTAssertEqual(SignatureArt.uprightFile(jpeg(orientation: 6), Codec()), [8, 24])
        let straight = jpeg(orientation: 1)
        XCTAssertEqual(SignatureArt.uprightFile(straight, Codec()), straight)
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]
        XCTAssertEqual(SignatureArt.uprightFile(png, Codec()), png)
    }

    func test_aMirroredOrientationFlipsTheLeftAndRight() {
        let image = PdfRgbaImage(2, 1, [1, 0, 0, 255, 2, 0, 0, 255])

        XCTAssertEqual(SignatureArt.upright(image, 2).rgba, [2, 0, 0, 255, 1, 0, 0, 255])
        XCTAssertEqual(SignatureArt.upright(image, 3).rgba, [2, 0, 0, 255, 1, 0, 0, 255])
    }

    func test_aBigPictureIsBroughtDownToTheLimitedWidth() throws {
        let big = PdfRgbaImage(1800, 400, [UInt8](repeating: 0, count: 1800 * 400 * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : 0 })

        let made = try XCTUnwrap(SignatureArt.fromFile([1], SignaturePictureCodec(big)))

        XCTAssertEqual(made.width, 900)
        XCTAssertEqual(made.height, 200)
    }

    func test_turningAPictureSwapsItsSidesAndFourTurnsComeBack() {
        let wide = PdfRgbaImage(4, 2, (0..<32).map { UInt8($0) })

        let turned = SignatureArt.turn(wide)

        XCTAssertEqual([turned.width, turned.height], [2, 4])
        // The top left pixel of a picture turned clockwise lands top right.
        XCTAssertEqual(Array(wide.rgba[0..<4]), Array(turned.rgba[4..<8]))
        let back = SignatureArt.turn(SignatureArt.turn(SignatureArt.turn(turned)))
        XCTAssertEqual(back.rgba, wide.rgba)
    }

    #if canImport(CoreText) && canImport(ImageIO)
    @MainActor
    func test_aTypedNameBecomesInkOnClear() throws {
        let image = try XCTUnwrap(SystemSignature().typed("Ada Lovelace", face: "Helvetica"))

        XCTAssertGreaterThan(image.width, image.height)
        XCTAssertGreaterThan(opaque(image), 100)
        XCTAssertLessThan(image.rgba[3], 8)
    }

    @MainActor
    func test_nothingTypedIsNoSignature() {
        XCTAssertNil(SystemSignature().typed("   ", face: "Helvetica"))
    }

    @MainActor
    func test_theSystemHasAFaceToTypeIn() {
        XCTAssertFalse(SystemSignature().faces.isEmpty)
    }

    @MainActor
    func test_aPhotoSavedAsAPngComesBackWithItsPixels() throws {
        let png = try PngWriter.encode(PdfRgbaImage(2, 1, [200, 0, 0, 255, 0, 200, 0, 128]))

        let back = try XCTUnwrap(ImageIOCodec().decodeFile(png)?.first)

        XCTAssertEqual(back.width, 2)
        XCTAssertEqual(back.rgba[0], 200)
        XCTAssertEqual(back.rgba[7], 128)
    }
    #endif
}
