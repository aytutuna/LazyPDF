import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactNameTextTests.cs: the same cases. Names carry text too: UTF-8 in their
// bytes, and font names that are not text a person wrote.

final class RedactNameTextTests: XCTestCase {
    private let utf8Font = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"
    private let over = PdfRect(90, 90, 300, 120)

    private func arialPage() throws -> PdfDocument {
        try ContentTestPdf.page("BT /F1 12 Tf 100 100 Td (Arial) Tj /F2 12 Tf 0 -50 Td (other) Tj ET", "/Font <</F1 5 0 R /F2 6 0 R>>",
                                [RedactionKit.helvetica, "<</Type /Font /Subtype /Type1 /BaseFont /Arial,Bold>>"])
    }

    func test_fontNameWithACommaIsNotTextToRedact() throws {
        for change in [false, true] {
            let document = try arialPage()
            var options = RedactionOptions()
            options.changeMetadata = change
            let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "Arial"), options)
            XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
            XCTAssertTrue(RedactionKit.holds(result.bytes, "Arial,Bold"))
        }
    }

    private func named() throws -> PdfDocument {
        // The name holds the UTF-8 bytes of the word, one to a character.
        let document = try ContentTestPdf.page("BT /F1 12 Tf 100 100 Td (M\u{FC}ller Schmidt) Tj ET", "/Font <</F1 5 0 R>>", [utf8Font])
        document.catalog["Keep"] = PdfName(Latin1.string(Array("M\u{FC}ller Schmidt".utf8)))
        return document
    }

    func test_nameHoldingTheWordInUtf8IsReported() throws {
        let document = try named()
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, over)])
        XCTAssertFalse(result.verification.isClean)
    }

    func test_nameHoldingTheWordInUtf8IsReplacedWhenMetadataMayChange() throws {
        let document = try named()
        var options = RedactionOptions()
        options.changeMetadata = true
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, over)], options)
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        XCTAssertFalse(try RedactionKit.everything(result.bytes).contains("Schmidt"))
    }
}
