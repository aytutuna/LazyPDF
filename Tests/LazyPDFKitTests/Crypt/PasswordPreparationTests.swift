import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/PasswordPreparationTests.cs: the same cases. The normalization is
// Foundation's here and the system's in the C#, which is why the golden files repeat these inputs.

final class PasswordPreparationTests: XCTestCase {
    func test_asciiStaysAsItIs() {
        XCTAssertEqual(PdfPasswords.prepare("Pass word 1"), Array("Pass word 1".utf8))
    }

    func test_spacesMapToSpaceAndSoftHyphensVanish() {
        XCTAssertEqual(PdfPasswords.prepare("a\u{A0}b\u{3000}c"), Array("a b c".utf8))
        XCTAssertEqual(PdfPasswords.prepare("a\u{AD}b\u{200D}c\u{FE0F}"), Array("abc".utf8))
    }

    func test_compatibilityCharactersAreNormalized() {
        XCTAssertEqual(PdfPasswords.prepare("\u{FB01}\u{2460}"), Array("fi1".utf8))
    }

    func test_prepareComposesAndDecomposeDecomposes() {
        XCTAssertEqual(PdfPasswords.prepare("e\u{301}"), [0xC3, 0xA9])
        XCTAssertEqual(PdfPasswords.decompose("\u{E9}"), [0x65, 0xCC, 0x81])
    }

    func test_longPasswordsAreCutAt127Bytes() {
        let text = String(repeating: "a", count: 200)

        XCTAssertEqual(PdfPasswords.prepare(text).count, 127)
        XCTAssertEqual(PdfPasswords.decompose(text).count, 127)
        XCTAssertEqual(PdfPasswords.prepare(String(repeating: "\u{E9}", count: 100)).count, 127)
    }

    func test_legacyUsesLatin1ThenFallsBackToUtf8() {
        XCTAssertEqual(PdfPasswords.legacy("c\u{E9}"), [0x63, 0xE9])
        XCTAssertEqual(PdfPasswords.legacy("\u{4E2D}"), Array("\u{4E2D}".utf8))
        XCTAssertTrue(PdfPasswords.legacy("").isEmpty)
    }
}
