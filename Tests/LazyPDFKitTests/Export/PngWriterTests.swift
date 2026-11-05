import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/PngWriterTests.cs: the same cases. The compressed bytes are the engine's own
// deflate, so a PNG is compared by the pixels it decodes to.

final class PngWriterTests: XCTestCase {
    private func gradient(_ w: Int, _ h: Int, _ alpha: UInt8) -> PdfRgbaImage {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                rgba[o] = UInt8(truncatingIfNeeded: x * 7 + y)
                rgba[o + 1] = UInt8(truncatingIfNeeded: y * 11)
                rgba[o + 2] = UInt8(truncatingIfNeeded: (x ^ y) * 13)
                rgba[o + 3] = alpha == 0 ? UInt8(truncatingIfNeeded: x * 255 / max(1, w - 1)) : alpha
            }
        }
        return PdfRgbaImage(w, h, rgba)
    }

    func test_opaqueColourRoundTrips() throws {
        for (w, h) in [(1, 1), (7, 5), (64, 33)] {
            let image = gradient(w, h, 255)
            let (dw, dh, rgba) = try ExportKit.pngDecode(PngWriter.encode(image))
            XCTAssertEqual([dw, dh], [w, h])
            XCTAssertEqual(rgba, image.rgba, "\(w) by \(h)")
        }
    }

    func test_transparencyRoundTrips() throws {
        let image = gradient(40, 20, 0)
        let png = try PngWriter.encode(image)
        XCTAssertEqual(png[25], 6)
        XCTAssertEqual(try ExportKit.pngDecode(png).rgba, image.rgba)
    }

    func test_grayPixelsAreWrittenAsOneChannel() throws {
        var rgba = [UInt8](repeating: 0, count: 16 * 16 * 4)
        for i in 0..<256 { (rgba[4 * i], rgba[4 * i + 1], rgba[4 * i + 2], rgba[4 * i + 3]) = (UInt8(i), UInt8(i), UInt8(i), 255) }
        let png = try PngWriter.encode(PdfRgbaImage(16, 16, rgba))
        XCTAssertEqual(png[25], 0)
        XCTAssertEqual(try ExportKit.pngDecode(png).rgba, rgba)
    }

    func test_smoothAreasCompressWell() throws {
        let flat = [UInt8](repeating: 200, count: 200 * 200 * 4)
        XCTAssertLessThan(try PngWriter.encode(PdfRgbaImage(200, 200, flat)).count, 600)
    }

    func test_dataThatDoesNotFitIsRefused() {
        for (w, h, length) in [(0, 1, 0), (2, 2, 7), (2, 2, 15)] {
            XCTAssertThrowsError(try PngWriter.encode(PdfRgbaImage(w, h, [UInt8](repeating: 0, count: length))), "\(w) by \(h), \(length) bytes") {
                XCTAssertTrue($0 is ArgumentException)
            }
        }
    }
}
