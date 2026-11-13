import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.App.Tests/TextDirectionTests.cs: the same cases.

final class TextDirectionTests: XCTestCase {
    func testTheFirstStrongLetterSetsTheDirection() {
        let cases: [(String, Bool)] = [
            ("שלום עולם", true), ("مرحبا", true), ("  123 مرحبا", true),
            ("Hello שלום", false), ("Merhaba dünya", false), ("123", false), ("", false),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(TextDirection.isRightToLeft(text), expected, text)
        }
    }
}
