import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Ocr/OcrVisualOrderTests.cs: the same cases.

final class OcrVisualOrderTests: XCTestCase {
    func test_leftToRightTextIsUnchanged() {
        for text in ["hello", "", "12.5%", "ğüşİı"] {
            XCTAssertEqual(OcrVisualOrder.flip(text), text, text)
        }
    }

    func test_rightToLeftWordsAreReversedAndKeepTheirNumbers() {
        let cases = [("שלום", "םולש"), ("שלום123", "123םולש"), ("a3.14ב", "בa3.14"), ("(שלום)", "(םולש)"), ("שלום עולם", "םלוע םולש")]
        for (logical, visual) in cases {
            XCTAssertEqual(OcrVisualOrder.flip(logical), visual, logical)
            XCTAssertEqual(OcrVisualOrder.flip(visual), logical, visual)
        }
    }

    func test_flippingTwiceGivesTheTextBack() {
        for text in ["مرحبا بالعالم 2026", "בדיקה (1,000) [x] «y» <z>", "abc שלום def"] {
            XCTAssertEqual(OcrVisualOrder.flip(OcrVisualOrder.flip(text)), text, text)
        }
    }
}
