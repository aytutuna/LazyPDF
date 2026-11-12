import XCTest
@testable import LazyPDFApp

final class OcrRendererTests: XCTestCase {
    func test_aPageWithinTheBudgetKeepsItsResolution() {
        XCTAssertEqual(OcrRenderer.cappedDpi(595, 842, 300), 300)
    }

    func test_aHugePageIsDrawnSmallerThanTheBudget() {
        let dpi = OcrRenderer.cappedDpi(2384, 3370, 300)

        XCTAssertLessThan(dpi, 300)
        let pixels = 2384 * dpi / 72 * (3370 * dpi / 72)
        XCTAssertEqual(pixels, Double(OcrRenderer.maxPixels), accuracy: 1)
    }
}
