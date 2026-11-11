#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import LazyPDFApp
import LazyPDFKit
import XCTest

// Mirrors windows/LazyPDF.App.Tests/WicImageCodecTests.cs, with files made here.

final class ImageIOCodecTests: XCTestCase {
    private let codec = ImageIOCodec()

    private func gradient(_ width: Int, _ height: Int, alpha: UInt8 = 255) -> PdfRgbaImage {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = UInt8(x * 255 / max(1, width - 1))
                rgba[i + 1] = UInt8(y * 255 / max(1, height - 1))
                rgba[i + 2] = 40
                rgba[i + 3] = alpha
            }
        }
        return PdfRgbaImage(width, height, rgba)
    }

    private func cgImage(_ image: PdfRgbaImage) -> CGImage {
        CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: CGDataProvider(data: Data(image.rgba) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    // A square of black and white bits, which is how a picture with too many pixels is made without holding them as bytes.
    private func blank(_ side: Int) -> CGImage {
        let bytesPerRow = (side + 7) / 8
        return CGImage(width: side, height: side, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: CGDataProvider(data: Data(count: bytesPerRow * side) as CFData)!, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    private func encode(_ type: String, _ frames: [CGImage]) throws -> [UInt8] {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, frames.count, nil))
        for frame in frames { CGImageDestinationAddImage(destination, frame, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return [UInt8](data as Data)
    }

    func test_aJpegIsMadeAndReadBackAtTheSameSize() throws {
        let jpeg = codec.encodeJpeg(gradient(64, 48), 90)

        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        let frame = try XCTUnwrap(codec.decodeFile(jpeg)).first
        XCTAssertEqual(codec.decodeFile(jpeg)?.count, 1)
        XCTAssertEqual(frame?.width, 64)
        XCTAssertEqual(frame?.height, 48)
        XCTAssertLessThan(abs(Int(frame!.rgba[(10 * 64 + 20) * 4]) - 20 * 255 / 63), 12)
    }

    func test_aLowerQualityIsSmaller() {
        let image = gradient(128, 128)

        XCTAssertLessThan(codec.encodeJpeg(image, 20).count, codec.encodeJpeg(image, 95).count)
    }

    func test_seeThroughPixelsGoOntoWhiteInAJpeg() throws {
        let jpeg = codec.encodeJpeg(PdfRgbaImage(8, 8, [UInt8](repeating: 0, count: 8 * 8 * 4)), 95)

        let frame = try XCTUnwrap(codec.decodeFile(jpeg)?.first)

        XCTAssertTrue(frame.rgba[0] > 240 && frame.rgba[1] > 240 && frame.rgba[2] > 240)
    }

    func test_aPngKeepsItsPixelsAndItsAlpha() throws {
        let image = gradient(16, 16, alpha: 128)

        let frames = try XCTUnwrap(codec.decodeFile(try encode("public.png", [cgImage(image)])))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].rgba.count, image.rgba.count)
        XCTAssertEqual(frames[0].rgba, image.rgba)
    }

    func test_aMostlyClearPngKeepsItsColours() throws {
        let image = gradient(16, 16, alpha: 3)

        let frames = try XCTUnwrap(codec.decodeFile(try encode("public.png", [cgImage(image)])))

        XCTAssertEqual(frames[0].rgba, image.rgba)
    }

    func test_aFileOfAnotherKindThatImageIOKnowsGivesNil() throws {
        XCTAssertNil(codec.decodeFile(try ApplePdfs.text()))
    }

    func test_aTiffWhoseSizeOverflowsComesBackAsAPlaceholderAndNotATrap() {
        func entry(_ tag: UInt16, _ type: UInt16, _ value: UInt32) -> [UInt8] {
            var bytes: [UInt8] = []
            for part in [UInt32(tag) | UInt32(type) << 16, 1, value] { bytes += withUnsafeBytes(of: part.littleEndian) { Array($0) } }
            return bytes
        }
        let big: UInt32 = 0xFFFF_FFF0
        var tiff: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0, 9, 0]
        for e in [entry(256, 4, big), entry(257, 4, big), entry(258, 3, 8), entry(259, 3, 1), entry(262, 3, 1),
                  entry(273, 4, 200), entry(277, 3, 1), entry(278, 4, big), entry(279, 4, 1)] { tiff += e }
        tiff += [0, 0, 0, 0]

        XCTAssertTrue((codec.decodeFile(tiff) ?? []).allSatisfy(\.tooBig))
    }

    func test_aTiffGivesEveryFrame() throws {
        let tiff = try encode("public.tiff", [cgImage(gradient(10, 10)), cgImage(gradient(20, 12)), cgImage(gradient(8, 8))])

        let frames = try XCTUnwrap(codec.decodeFile(tiff))

        XCTAssertEqual(frames.map(\.width), [10, 20, 8])
        XCTAssertEqual(frames.map(\.height), [10, 12, 8])
    }

    func test_aBmpAndAGifAreRead() throws {
        XCTAssertEqual(codec.decodeFile(try encode("com.microsoft.bmp", [cgImage(gradient(9, 9))]))?.count, 1)
        XCTAssertEqual(codec.decodeFile(try encode("com.compuserve.gif", [cgImage(gradient(9, 9))]))?.count, 1)
    }

    func test_aDctStreamIsDecodedAsAJpeg() throws {
        let jpeg = codec.encodeJpeg(gradient(32, 32), 90)

        let image = try XCTUnwrap(codec.decode(jpeg, "DCTDecode"))

        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 32)
        XCTAssertNil(codec.decode(jpeg, "JBIG2Decode"))
    }

    func test_whatIsNotAPictureGivesNil() {
        XCTAssertNil(codec.decodeFile([]))
        XCTAssertNil(codec.decodeFile(Array("this is text, not a picture".utf8)))
        XCTAssertNil(codec.decode([1, 2, 3], "DCTDecode"))
    }

    func test_thePicturesOfAPdfFromPicturesRoundTrip() throws {
        let jpeg = codec.encodeJpeg(gradient(80, 60), 90)
        let png = try encode("public.png", [cgImage(gradient(40, 40))])

        let made = try PdfFromPictures.create([jpeg, png, [1, 2, 3]], codec)

        XCTAssertEqual(made.pages, 2)
        XCTAssertEqual(made.unreadable, [2])
        XCTAssertEqual(try PdfDocument.open(made.bytes).pages.count, 2)
    }

    func test_aPictureWithTooManyPixelsComesBackAsAPlaceholder() throws {
        let png = try encode("public.png", [blank(16384)])

        let frames = try XCTUnwrap(codec.decodeFile(png))

        XCTAssertEqual(frames.map(\.tooBig), [true])
        XCTAssertEqual(frames.map(\.width), [16384])
    }

    func test_aFrameWithTooManyPixelsDoesNotTakeTheOtherFramesWithIt() throws {
        let tiff = try encode("public.tiff", [blank(8), blank(16384), blank(16)])

        let frames = codec.decodeFile(tiff)

        XCTAssertEqual(frames?.map(\.width), [8, 16384, 16])
        XCTAssertEqual(frames?.map(\.tooBig), [false, true, false])
    }
}
#endif
