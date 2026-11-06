import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/PixelCompareTests.cs: the same cases. The random numbers come from a port of
// System.Random(seed), so the pages are the C# pages.

/// The pages of PixelCompareTests, which the golden dump makes too.
enum PixelPages {
    final class Canvas {
        let width: Int
        let height: Int
        var gray: [UInt8]

        init(_ width: Int, _ height: Int) {
            self.width = width
            self.height = height
            gray = [UInt8](repeating: 255, count: width * height)
        }

        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ value: UInt8) {
            for yy in stride(from: max(0, y), to: min(height, y + h), by: 1) {
                for xx in stride(from: max(0, x), to: min(width, x + w), by: 1) { gray[yy * width + xx] = value }
            }
        }

        func toImage() -> PdfRgbaImage {
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            for i in 0..<gray.count {
                rgba[i * 4] = gray[i]
                rgba[i * 4 + 1] = gray[i]
                rgba[i * 4 + 2] = gray[i]
                rgba[i * 4 + 3] = 255
            }
            return PdfRgbaImage(width, height, rgba)
        }
    }

    /// A page of text-like lines of word blocks, the same for the same seed; `scale` grows it.
    static func text(_ width: Int = 600, _ height: Int = 800, scale: Double = 1, seed: Int = 5) -> Canvas {
        var random = DotNetRandom(seed)
        let canvas = Canvas(Int(Double(width) * scale), Int(Double(height) * scale))
        for line in 0..<28 {
            var x = 60
            while x < 520 {
                let w = 20 + random.next(50)
                if x + w > 540 { break }
                canvas.fill(Int(Double(x) * scale), Int(Double(70 + line * 24) * scale), Int(Double(w) * scale), Int(10 * scale), 20)
                x += w + 10
            }
        }
        return canvas
    }

    /// The picture seen through a turn by `degrees` clockwise and a shift, as a scanner would make it.
    static func scan(_ source: Canvas, _ degrees: Double, _ shiftX: Int, _ shiftY: Int, noise: Int = 0) -> PdfRgbaImage {
        let result = Canvas(source.width, source.height)
        let a = degrees * Double.pi / 180, cx = Double(source.width - 1) / 2.0, cy = Double(source.height - 1) / 2.0
        var random = DotNetRandom(3)
        for y in 0..<source.height {
            for x in 0..<source.width {
                let px = Double(x) - cx - Double(shiftX), py = Double(y) - cy - Double(shiftY)
                let sx = Int((px * cos(a) + py * sin(a) + cx).rounded(.toNearestOrEven))
                let sy = Int((-px * sin(a) + py * cos(a) + cy).rounded(.toNearestOrEven))
                let value = sx < 0 || sy < 0 || sx >= source.width || sy >= source.height ? 255 : Int(source.gray[sy * source.width + sx])
                let jitter = noise == 0 ? 0 : -noise + random.next(2 * noise + 1)
                result.gray[y * source.width + x] = UInt8(min(max(value + jitter, 0), 255))
            }
        }
        return result.toImage()
    }
}

final class PixelCompareTests: XCTestCase {
    private typealias Canvas = PixelPages.Canvas

    private func text(_ width: Int = 600, _ height: Int = 800, scale: Double = 1, seed: Int = 5) -> Canvas {
        PixelPages.text(width, height, scale: scale, seed: seed)
    }

    private func scan(_ source: Canvas, _ degrees: Double, _ shiftX: Int, _ shiftY: Int, noise: Int = 0) -> PdfRgbaImage {
        PixelPages.scan(source, degrees, shiftX, shiftY, noise: noise)
    }

    func test_identicalPagesHaveNoDifferences() throws {
        let page = text().toImage()
        let result = try PixelComparer.compare(page, page, 72)
        XCTAssertTrue(result.differences.isEmpty)
        XCTAssertEqual(result.similarity, 1.0)
        XCTAssertEqual(result.overlay.width, 600)
        XCTAssertEqual(result.overlay.height, 800)
        XCTAssertEqual(result.alignment.shiftX, 0)
    }

    func test_twoBlankPagesAreSimilar() throws {
        let blank = Canvas(100, 100).toImage()
        let result = try PixelComparer.compare(blank, blank, 72)
        XCTAssertEqual(result.similarity, 1.0)
        XCTAssertTrue(result.differences.isEmpty)
    }

    func test_addedBlockIsOneRegionInPoints() throws {
        let before = text()
        let after = text()
        after.fill(200, 740, 80, 14, 0)
        let result = try PixelComparer.compare(before.toImage(), after.toImage(), 72)
        let difference = try CompareKit.single(result.differences)
        CompareKit.assertInRange(difference.region.x, 198, 202)
        CompareKit.assertInRange(difference.region.y, 738, 742)
        CompareKit.assertInRange(difference.region.width, 78, 82)
        CompareKit.assertInRange(difference.region.height, 12, 16)
        CompareKit.assertInRange(Double(difference.pixels), Double(80 * 14 - 200), Double(80 * 14))
        CompareKit.assertInRange(result.similarity, 0.9, 0.999)
        // The overlay shows ink only the new page has in green.
        let at = (746 * 600 + 240) * 4
        XCTAssertEqual(result.overlay.rgba[at], 0)
        XCTAssertEqual(result.overlay.rgba[at + 1], 170)
        XCTAssertEqual(result.overlay.rgba[at + 2], 0)
    }

    func test_removedBlockIsRedInTheOverlay() throws {
        let before = text()
        let after = text()
        before.fill(200, 740, 80, 14, 0)
        let result = try PixelComparer.compare(before.toImage(), after.toImage(), 72)
        _ = try CompareKit.single(result.differences)
        let at = (746 * 600 + 240) * 4
        XCTAssertEqual(result.overlay.rgba[at], 220)
        XCTAssertEqual(result.overlay.rgba[at + 1], 0)
        XCTAssertEqual(result.overlay.rgba[at + 2], 0)
    }

    func test_regionsFollowTheResolution() throws {
        let before = text()
        let after = text()
        after.fill(200, 740, 80, 14, 0)
        let region = try CompareKit.single(try PixelComparer.compare(before.toImage(), after.toImage(), 144).differences).region
        CompareKit.assertInRange(region.x, 99, 101)
        CompareKit.assertInRange(region.width, 39, 41)
    }

    func test_separateChangesAreSeparateRegions() throws {
        let before = text()
        let after = text()
        after.fill(100, 740, 30, 12, 0)
        after.fill(400, 40, 30, 12, 0)
        let result = try PixelComparer.compare(before.toImage(), after.toImage(), 72)
        XCTAssertEqual(result.differences.count, 2)
    }

    func test_differencesBelowTheThresholdAreIgnored() throws {
        let before = text()
        let after = text()
        after.fill(200, 740, 80, 14, 230)
        XCTAssertTrue(try PixelComparer.compare(before.toImage(), after.toImage(), 72).differences.isEmpty)
        _ = try CompareKit.single(try PixelComparer.compare(before.toImage(), after.toImage(), 72, PixelOptions(threshold: 10)).differences)
    }

    func test_scanNoiseIsNotADifference() throws {
        let page = text()
        let result = try PixelComparer.compare(page.toImage(), scan(page, 0, 0, 0, noise: 3), 72)
        XCTAssertTrue(result.differences.isEmpty)
        XCTAssertEqual(result.similarity, 1.0)
    }

    func test_aToleranceNearTheLargestIntSeesTheWholePage() throws {
        let page = Canvas(16, 16)
        let options = PixelOptions(tolerance: Int(Int32.max), align: false)
        let result = try PixelComparer.compare(page.toImage(), page.toImage(), 72, options)
        XCTAssertTrue(result.differences.isEmpty)
        XCTAssertEqual(result.similarity, 1.0)
    }

    func test_onePixelShiftWithinToleranceIsNoDifference() throws {
        let page = text()
        let options = PixelOptions(align: false)
        XCTAssertTrue(try PixelComparer.compare(page.toImage(), scan(page, 0, 1, 0), 72, options).differences.isEmpty)
        XCTAssertFalse(try PixelComparer.compare(page.toImage(), scan(page, 0, 4, 0), 72, options).differences.isEmpty)
    }

    func test_shiftedScanIsAlignedFirst() throws {
        let page = text()
        let shifted = scan(page, 0, 7, -5, noise: 3)
        let plain = try PixelComparer.compare(page.toImage(), shifted, 72, PixelOptions(align: false))
        let aligned = try PixelComparer.compare(page.toImage(), shifted, 72)
        XCTAssertTrue(plain.similarity < 0.6, "\(plain.similarity)")
        CompareKit.assertInRange(aligned.similarity, 0.97, 1)
        CompareKit.assertInRange(aligned.alignment.shiftX, 6, 8)
        CompareKit.assertInRange(aligned.alignment.shiftY, -6, -4)
        CompareKit.assertInRange(aligned.alignment.degrees, -0.2, 0.2)
        XCTAssertTrue(aligned.differences.count < 5)
    }

    func test_rotatedAndShiftedScanIsAligned() throws {
        let page = text()
        let scanned = scan(page, 0.8, 6, 4, noise: 2)
        let plain = try PixelComparer.compare(page.toImage(), scanned, 72, PixelOptions(align: false))
        let aligned = try PixelComparer.compare(page.toImage(), scanned, 72)
        XCTAssertTrue(plain.similarity < 0.6, "\(plain.similarity)")
        CompareKit.assertInRange(aligned.similarity, 0.85, 1)
        CompareKit.assertInRange(aligned.alignment.degrees, 0.5, 1.1)
        CompareKit.assertInRange(aligned.alignment.shiftX, 4, 8)
        CompareKit.assertInRange(aligned.alignment.shiftY, 2, 6)
    }

    func test_scanTurnedTheOtherWayIsAlignedToo() throws {
        let page = text()
        let aligned = try PixelComparer.compare(page.toImage(), scan(page, -1.2, -9, 3), 72)
        CompareKit.assertInRange(aligned.similarity, 0.8, 1)
        CompareKit.assertInRange(aligned.alignment.degrees, -1.6, -0.8)
    }

    func test_changeInAShiftedScanIsStillFound() throws {
        let page = text()
        let changed = text()
        changed.fill(100, 420, 120, 14, 0)
        let result = try PixelComparer.compare(page.toImage(), scan(changed, 0.5, 5, -3), 72)
        XCTAssertFalse(result.differences.isEmpty)
        let biggest = try XCTUnwrap(result.differences.max { $0.pixels < $1.pixels })
        CompareKit.assertInRange(biggest.region.x, 95, 125)
        CompareKit.assertInRange(biggest.region.y, 408, 430)
        XCTAssertTrue(biggest.region.width > 90)
    }

    func test_pagesOfDifferentSizesAreFitted() throws {
        let small = text()
        let large = text(scale: 1.25)
        let result = try PixelComparer.compare(small.toImage(), large.toImage(), 72)
        XCTAssertEqual(result.overlay.width, 750)
        XCTAssertEqual(result.overlay.height, 1000)
        CompareKit.assertInRange(result.similarity, 0.8, 1)
    }

    private final class FakeRenderer: PageRenderer {
        private let image: PdfRgbaImage?
        var calls: [(page: Int, dpi: Double)] = []

        init(_ image: PdfRgbaImage?) {
            self.image = image
        }

        func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
            calls.append((pageIndex, dpi))
            return image
        }
    }

    func test_rendererOverloadAsksBothSides() throws {
        let one = FakeRenderer(text().toImage())
        let two = FakeRenderer(text().toImage())
        let result = try PixelComparer.compare(one, 3, two, 5, 100)
        XCTAssertNotNil(result)
        XCTAssertEqual(one.calls.count, 1)
        XCTAssertEqual(one.calls[0].page, 3)
        XCTAssertEqual(one.calls[0].dpi, 100.0)
        XCTAssertEqual(two.calls.count, 1)
        XCTAssertEqual(two.calls[0].page, 5)
        XCTAssertEqual(two.calls[0].dpi, 100.0)
    }

    func test_rendererThatCannotDrawGivesNull() throws {
        XCTAssertNil(try PixelComparer.compare(FakeRenderer(nil), 0, FakeRenderer(text().toImage()), 0, 72))
    }

    func test_emptyOrShortImagesAreRefused() throws {
        let good = text(100, 100).toImage()
        XCTAssertThrowsError(try PixelComparer.compare(PdfRgbaImage(0, 0, []), good, 72)) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try PixelComparer.compare(good, PdfRgbaImage(10, 10, [UInt8](repeating: 0, count: 10)), 72)) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_transparentPixelsCountAsWhite() throws {
        let opaque = Canvas(50, 50).toImage()
        let clear = PdfRgbaImage(50, 50, [UInt8](repeating: 0, count: 50 * 50 * 4))
        XCTAssertTrue(try PixelComparer.compare(opaque, clear, 72).differences.isEmpty)
    }
}
