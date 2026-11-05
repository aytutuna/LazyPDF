import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Tables/GlyphListTests.cs: the same cases. Non-ASCII text is written
// as scalars.

final class GlyphListTests: XCTestCase {
    func test_maps() {
        let cases = [
            ("A", "A"), ("space", " "), ("Euro", "\u{20AC}"), ("fi", "\u{FB01}"), ("uni0041", "A"),
            ("uni00410042", "AB"), ("u1F600", "\u{1F600}"), ("u0041", "A"), ("a.alt", "a"), ("A.swash.1", "A"),
            ("f_i", "fi"), ("f_f_uni0069", "ffi"), ("a1", "\u{2701}"), ("dalethatafpatah", "\u{5D3}\u{5B2}"),
        ]
        for (name, text) in cases {
            XCTAssertEqual(GlyphList.unicodeOf(name), text, name)
        }
    }

    func test_unmappedNamesGiveNull() {
        for name in ["", ".notdef", "g123", "cid1234", "uniD800", "uni004", "uniGGGG", "u110000", "u+041", "_"] {
            XCTAssertNil(GlyphList.unicodeOf(name), name)
        }
    }

    func test_componentsThatDoNotMapAreLeftOut() {
        XCTAssertEqual(GlyphList.unicodeOf("a_g123_b"), "ab")
    }

    func test_longNamesGiveNull() {
        XCTAssertNil(GlyphList.unicodeOf(String(repeating: "a", count: 5000)))
    }

    func test_nameOfPrefersTheEncodingNames() {
        let cases = [(0x20, "space"), (0x41, "A"), (0x20AC, "Euro"), (0xFB01, "fi"), (0x2022, "bullet")]
        for (cp, name) in cases {
            XCTAssertEqual(GlyphList.nameOf(cp), name, String(cp, radix: 16))
        }
    }

    func test_nameOfFallsBackToUniAndU() {
        XCTAssertEqual(GlyphList.nameOf(0x4E2D), "uni4E2D")
        XCTAssertEqual(GlyphList.nameOf(0x1F600), "u1F600")
        XCTAssertEqual(GlyphList.nameOf(0xD800), ".notdef")
        XCTAssertEqual(GlyphList.nameOf(-1), ".notdef")
        XCTAssertEqual(GlyphList.nameOf(0x110000), ".notdef")
    }

    func test_namesAndTextRoundTrip() throws {
        var seen = Set<String>()
        for case let name? in PdfEncodings.winAnsi + PdfEncodings.standard + PdfEncodings.macRoman where seen.insert(name).inserted {
            let text = try XCTUnwrap(GlyphList.unicodeOf(name), name)
            let first = try XCTUnwrap(text.unicodeScalars.first)
            XCTAssertEqual(GlyphList.unicodeOf(GlyphList.nameOf(Int(first.value))), text, name)
        }
    }

    func test_zapfNames() {
        XCTAssertEqual(GlyphList.zapfNameOf(0x2701), "a1")
        XCTAssertNil(GlyphList.zapfNameOf(0x41))
    }
}
