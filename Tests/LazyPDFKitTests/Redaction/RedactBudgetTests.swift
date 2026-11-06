import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactBudgetTests.cs: the same case.

final class RedactBudgetTests: XCTestCase {
    func test_a_page_too_big_to_scan_to_the_end_becomes_a_picture_not_passed_through() throws {
        let document = try RedactionKit.page("/F6 Do BT /F1 12 Tf 100 700 Td (secret) Tj ET", "/XObject <</F6 6 0 R>>") { pdf in
            for i in 6..<13 {
                pdf.stream(i, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</XObject <</F\(i + 1) \(i + 1) 0 R>>>>",
                           String(repeating: "/F\(i + 1) Do ", count: 12))
            }
            pdf.stream(13, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0 0 m")
        }

        let mark = RedactionMark.fromRect(0, PdfRect(90, 690, 300, 720))

        try RedactionKit.assertFlattened(document, [mark], "secret")
    }
}
