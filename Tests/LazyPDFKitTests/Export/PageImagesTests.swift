import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/PageImagesTests.cs: the same cases. A dpi or quality out of range is an
// `ArgumentException`, where the C# throws ArgumentOutOfRangeException.

final class PageImagesTests: XCTestCase {
    private final class Reuse: PageRenderer {
        private let image: PdfRgbaImage

        init(_ image: PdfRgbaImage) {
            self.image = image
        }

        func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { image }
    }

    private final class Capture: ImageCodec {
        var seen: PdfRgbaImage?

        func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }

        func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { nil }

        func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] {
            seen = image
            return []
        }
    }

    func test_thePageComesBackAsAPngOfTheRenderedPixels() throws {
        let renderer = ExportFakeRenderer(30, 20)
        let png = try XCTUnwrap(PageImages.png(renderer, 1, 150))
        let (w, h, rgba) = try ExportKit.pngDecode(png)
        XCTAssertEqual([w, h], [30, 20])
        XCTAssertEqual(rgba, renderer.render(1, 150)?.rgba)
    }

    func test_transparencyIsKeptInThePng() throws {
        let png = try XCTUnwrap(PageImages.png(ExportFakeRenderer(8, 8, alpha: 100), 0, 72))
        XCTAssertEqual(try ExportKit.pngDecode(png).rgba[3], 100)
    }

    func test_aPageTheRendererCannotDrawGivesNull() throws {
        XCTAssertNil(try PageImages.png(ExportFakeRenderer(8, 8), 5, 72))
        XCTAssertNil(try PageImages.jpeg(ExportFakeRenderer(8, 8), ExportFakeCodec(), 5, 72))
    }

    func test_aJpegTheCodecCannotWriteGivesNull() throws {
        XCTAssertNil(try PageImages.jpeg(ExportFakeRenderer(8, 8), Capture(), 0, 72))
    }

    func test_theJpegComesFromTheCodecAndTransparencyIsFlattenedOnWhite() throws {
        let renderer = ExportFakeRenderer(8, 8, alpha: 0)
        let jpeg = try PageImages.jpeg(renderer, ExportFakeCodec(), 0, 72, 60)
        XCTAssertEqual(jpeg, [0xFF, 0xD8, 60, 1, 0xFF, 0xD9])
    }

    func test_flatteningLeavesTheRenderersPixelsAlone() throws {
        let shared = PdfRgbaImage(1, 1, [10, 20, 30, 0])
        let renderer = Reuse(shared)
        let codec = Capture()
        _ = try PageImages.jpeg(renderer, codec, 0, 72)
        XCTAssertEqual(codec.seen?.rgba, [255, 255, 255, 255])
        XCTAssertEqual(shared.rgba, [10, 20, 30, 0])
    }

    func test_aDpiOutOfRangeIsRefused() {
        for dpi in [0, -1, 1201, Double.nan] {
            XCTAssertThrowsError(try PageImages.png(ExportFakeRenderer(8, 8), 0, dpi), "dpi \(dpi)") { XCTAssertTrue($0 is ArgumentException) }
            XCTAssertThrowsError(try PageImages.jpeg(ExportFakeRenderer(8, 8), ExportFakeCodec(), 0, dpi), "dpi \(dpi)") { XCTAssertTrue($0 is ArgumentException) }
        }
    }

    func test_aQualityOutOfRangeIsRefused() {
        for quality in [0, 101] {
            XCTAssertThrowsError(try PageImages.jpeg(ExportFakeRenderer(8, 8), ExportFakeCodec(), 0, 72, quality), "quality \(quality)") { XCTAssertTrue($0 is ArgumentException) }
        }
    }
}
