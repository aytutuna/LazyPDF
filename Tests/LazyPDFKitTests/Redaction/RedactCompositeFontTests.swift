import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactCompositeFontTests.cs: the same cases. The C# embeds Arial from the
// machine; here the font is a Type0 font written by the test, with two-byte codes that are the characters themselves, a
// ToUnicode map and no font program, which is all the redaction reads.

final class RedactCompositeFontTests: XCTestCase {
    // Two-byte codes, drawing the text as hex strings.
    private func embedded(_ text: String, _ content: ([UInt8]) -> String) throws -> PdfDocument {
        let map = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Test def 1 begincodespacerange <0000> <FFFF> endcodespacerange "
            + "1 beginbfrange <0000> <FFFF> <0000> endbfrange endcmap end end"
        let document = try RedactionKit.page("", "") { pdf in
            pdf.obj(6, "<</Type /Font /Subtype /Type0 /BaseFont /TestSans /Encoding /Identity-H /DescendantFonts [7 0 R] /ToUnicode 8 0 R>>")
            pdf.obj(7, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /TestSans /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 600>>")
            pdf.stream(8, "", map)
        }
        let page = document.pages[0]
        let fonts = try XCTUnwrap(document.dict(ContentResources.forEdit(document, page), "Font"))
        fonts["F2"] = PdfReference(6, 0)
        let encoded = text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        page.dictionary["Contents"] = try document.add(PdfStream(PdfDictionary(), data: Latin1.bytes(content(encoded))))
        return document
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }

    func test_aCodeNeverEndsInTheMiddleOfAnotherAndTheRestStays() throws {
        let text = "Hello SECRETWORD there"
        let document = try embedded(text) { "BT /F2 14 Tf 50 700 Td <\(self.hex($0))> Tj ET" }
        let before = RedactionKit.glyphs(document)
        XCTAssertEqual(RedactionKit.text(before), text)
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "SECRETWORD"))
        let output = try RedactionKit.open(result)
        let after = RedactionKit.glyphs(output)
        XCTAssertEqual(RedactionKit.text(after), "Hello  there")
        let expected = Array(before.prefix(6)) + Array(before.dropFirst(16))
        XCTAssertEqual(after.count, expected.count)
        for i in 0..<min(expected.count, after.count) {
            XCTAssertEqual(expected[i].x, after[i].x, accuracy: 0.01)
            XCTAssertEqual(expected[i].y, after[i].y, accuracy: 0.01)
        }
        XCTAssertFalse(RedactionKit.holds(result.bytes, "SECRETWORD"))
    }

    func test_kerningBetweenTwoByteStringsIsKept() throws {
        let text = "ab SECRET cd"
        let document = try embedded(text) { bytes in
            let digits = Array(self.hex(bytes))
            return "BT /F2 14 Tf 50 700 Td [<\(String(digits[..<12]))> -300 <\(String(digits[12...]))>] TJ ET"
        }
        let before = RedactionKit.glyphs(document)
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "SECRET"))
        let output = try RedactionKit.open(result)
        let after = RedactionKit.glyphs(output)
        XCTAssertEqual(RedactionKit.text(after), "ab  cd")
        XCTAssertEqual(try XCTUnwrap(before.last).x, try XCTUnwrap(after.last).x, accuracy: 0.01)
    }
}
