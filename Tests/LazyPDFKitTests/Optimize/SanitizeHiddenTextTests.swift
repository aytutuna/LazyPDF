import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/SanitizeHiddenTextTests.cs: the same cases.

final class SanitizeHiddenTextTests: XCTestCase {
    private func hidden(_ content: String) throws -> Int {
        let file = OptimizeKit.build(content, "/Font <</F1 5 0 R>> /ExtGState <</GS0 <</ca 0>>>>", { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        })
        let document = try PdfDocument.open(file)
        return SanitizeKit.count(try PdfSanitizer(document).scan(), .hiddenText)
    }

    func test_textPaintedWithZeroOpacityIsHidden() throws {
        XCTAssertEqual(1, try hidden("/GS0 gs BT /F1 12 Tf 10 100 Td (GHOST) Tj ET"))
    }

    func test_textWithTheOpacityRestoredIsNot() throws {
        XCTAssertEqual(0, try hidden("q /GS0 gs Q BT /F1 12 Tf 10 100 Td (SHOWN) Tj ET"))
    }

    func test_textOutsideThePageIsHidden() throws {
        XCTAssertEqual(1, try hidden("BT /F1 12 Tf -5000 100 Td (AWAY) Tj ET BT /F1 12 Tf 10 100 Td (HERE) Tj ET"))
    }

    func test_textCutAwayByAClipIsHidden() throws {
        XCTAssertEqual(1, try hidden("q 0 0 20 20 re W n BT /F1 12 Tf 100 100 Td (CLIPPED) Tj ET Q"))
    }

    func test_textUnderAClipThatMissesThePageIsHidden() throws {
        XCTAssertEqual(1, try hidden("q 300 300 10 10 re W n BT /F1 12 Tf 0 0 Td (SECRET) Tj ET Q"))
    }

    func test_textTooSmallToReadIsHidden() throws {
        XCTAssertEqual(1, try hidden("BT /F1 0.3 Tf 10 100 Td (TINY) Tj ET BT /F1 8 Tf 10 50 Td (SMALL) Tj ET"))
    }

    func test_textThatAlsoClipsIsJudgedLikeTextThatDoesNot() throws {
        for content in ["/GS0 gs BT 4 Tr /F1 12 Tf 10 100 Td (GHOST) Tj ET", "BT 4 Tr /F1 12 Tf -5000 100 Td (AWAY) Tj ET", "BT 6 Tr /F1 12 Tf -5000 100 Td (AWAY) Tj ET"] {
            XCTAssertEqual(1, try hidden(content), content)
        }
    }

    func test_readableTextOnThePageIsNotHidden() throws {
        XCTAssertEqual(0, try hidden("BT /F1 12 Tf 10 100 Td (PLAIN) Tj ET"))
    }
}
