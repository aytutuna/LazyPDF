#if canImport(SwiftUI)
import CoreGraphics
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

final class TileImageTests: XCTestCase {
    func test_aTileKeepsItsSizeAndColours() throws {
        let tile = TileBitmap(PdfRgbaImage(2, 1, [255, 0, 0, 255, 0, 0, 255, 255]), .none)

        let image = try XCTUnwrap(tile.cgImage)

        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        var pixels = [UInt8](repeating: 0, count: 8)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        XCTAssertEqual(pixels, [255, 0, 0, 255, 0, 0, 255, 255])
    }

    func test_anEmptyTileHasNoImage() {
        XCTAssertNil(TileBitmap(PdfRgbaImage(0, 0, []), .none).cgImage)
    }
}
#endif
