import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/PdfTextTests.cs: the same cases.

final class PdfTextTests: XCTestCase {
    func test_asciiStaysPdfDocEncoded() {
        XCTAssertEqual(PdfText.encode("Quarterly report"), Array("Quarterly report".utf8))
    }

    func test_latinTextFitsPdfDocEncoding() {
        // 0xE9 is e-acute in both PDFDocEncoding and Latin-1; the bullet and the euro sit in the 0x80 block.
        XCTAssertEqual(PdfText.encode("caf\u{E9} \u{2022}\u{20AC}"), [0x63, 0x61, 0x66, 0xE9, 0x20, 0x80, 0xA0])
        XCTAssertEqual(PdfText.decode(PdfText.encode("caf\u{E9} \u{2022}\u{20AC}")), "caf\u{E9} \u{2022}\u{20AC}")
    }

    func test_otherScriptsGoToUtf16WithMark() {
        let bytes = PdfText.encode("T\u{FC}rk\u{E7}e \u{11F}")
        XCTAssertEqual(Array(bytes.prefix(2)), [0xFE, 0xFF])
        XCTAssertEqual(PdfText.decode(bytes), "T\u{FC}rk\u{E7}e \u{11F}")
    }

    func test_surrogatePairsSurvive() {
        let text = "mark \u{1F4D8}"
        XCTAssertEqual(PdfText.decode(PdfText.encode(text)), text)
    }

    func test_decodesUtf16LittleEndianAndUtf8WithMark() {
        XCTAssertEqual(PdfText.decode([0xFF, 0xFE, 0x61, 0, 0x62, 0, 0x16, 0x04]), "ab\u{416}")
        XCTAssertEqual(PdfText.decode([0xEF, 0xBB, 0xBF] + Array("ab\u{416}".utf8)), "ab\u{416}")
    }

    func test_languageEscapeIsDropped() {
        let bytes: [UInt8] = [0xFE, 0xFF, 0, 0x1B, 0, UInt8(ascii: "e"), 0, UInt8(ascii: "n"), 0, 0x1B, 0, UInt8(ascii: "H"), 0, UInt8(ascii: "i")]
        XCTAssertEqual(PdfText.decode(bytes), "Hi")
    }

    func test_unassignedPdfDocCodesReadAsLatin1() {
        XCTAssertEqual(PdfText.decode([0x61, 0x7F, 0x62]), "a\u{7F}b")
    }

    func test_objectIsHexWhenLiteralWouldNeedEscapes() {
        XCTAssertFalse(PdfText.toObject("plain").isHex)
        XCTAssertTrue(PdfText.toObject("\u{416}").isHex)
    }

    func test_emptyAndControlCharactersRoundTrip() {
        XCTAssertEqual(PdfText.decode(PdfText.encode("")), "")
        XCTAssertEqual(PdfText.decode(PdfText.encode("a\tb\nc")), "a\tb\nc")
        XCTAssertEqual(PdfText.decode(PdfText.encode("a\u{1}b")), "a\u{1}b")
    }

    func test_readsStreamsAndStrings() throws {
        let document = try PdfDocument.open(TestPdf.simple(1))
        XCTAssertEqual(PdfText.read(document, document.pages[0].dictionary["Contents"]), "BT /F1 12 Tf (1) Tj ET")
        XCTAssertNil(PdfText.read(document, PdfNumber(1)))
        XCTAssertNil(PdfText.read(document, nil))
    }

    // Damaged shapes the C# tests do not feed: an odd byte count, a lone surrogate, an unterminated language escape.
    func test_damagedUtf16ReadsAsReplacementCharacters() {
        XCTAssertEqual(PdfText.decode([0xFE, 0xFF, 0, 0x61, 0]), "a\u{FFFD}")
        XCTAssertEqual(PdfText.decode([0xFE, 0xFF, 0xD8, 0x00, 0, 0x61]), "\u{FFFD}a")
        XCTAssertEqual(PdfText.decode([0xFE, 0xFF, 0, 0x61, 0, 0x1B, 0, 0x65]), "a")
        XCTAssertEqual(PdfText.decode([0xFE]), "\u{FE}")
    }
}
