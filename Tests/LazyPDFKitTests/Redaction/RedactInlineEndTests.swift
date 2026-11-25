import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactInlineEndTests.cs: the same cases. Content that a viewer may read
// differently from the parser becomes a picture, since what the scan did not see is never cut.

final class RedactInlineEndTests: XCTestCase {
    private let image = "q BI /W 1 /H 1 /BPC 8 /CS /G /F /AHx ID "
    private let shows = " Q BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET "
    private let near = PdfRect(90, 90, 200, 120)

    private func assertFlat(_ content: String) throws {
        let document = try RedactionKit.page(content)
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, near)], "ZQXCYCLE")
    }

    func test_endRightAfterTheFilterDataFlattensThePage() throws {
        try assertFlat(image + "00>EI" + shows + image + "00> EI Q")
    }

    func test_endFollowedByACommentFlattensThePage() throws {
        try assertFlat(image + "00> EI%\u{FF}\n" + shows + image + "00> EI Q")
    }

    func test_showOperatorWithoutTheOperandItReadsFlattensThePage() throws {
        for content in ["BT /F1 12 Tf 100 100 Td /ZQXCYCLE Tj ET", "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) TJ ET", "BT /F1 12 Tf 100 100 Td Tj ET"] {
            try assertFlat(content)
        }
    }
}
