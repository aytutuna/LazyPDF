import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactCoverageTests.cs: the same cases.

final class RedactCoverageTests: XCTestCase {
    private let formEntries = "/Type /XObject /Subtype /Form /BBox [0 0 600 800]"
    private let mark = PdfRect(40, 690, 300, 720)

    // Forms 1 to depth, each painting the next; the last shows the text.
    private func chain(_ depth: Int) throws -> PdfDocument {
        try RedactionKit.page("/Fm1 Do", "/XObject <</Fm1 6 0 R>>") { pdf in
            for i in 1..<max(depth, 1) {
                pdf.stream(5 + i, "\(self.formEntries) /Resources <</XObject <</Fm\(i + 1) \(6 + i) 0 R>>>>", "/Fm\(i + 1) Do")
            }
            pdf.stream(5 + depth, "\(self.formEntries) /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 50 700 Td (secret) Tj ET")
        }
    }

    func test_formsNestedBeyondTheDepthTheWalkerEntersMakeThePagePicture() throws {
        let document = try chain(22)
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, mark)], "secret")
    }

    func test_formsWithinTheDepthAreRedacted() throws {
        let document = try chain(10)
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, mark)])
        XCTAssertEqual(result.report.glyphs, 6)
        XCTAssertTrue(result.verification.isClean)
    }

    private func unreadable(_ box: String) throws -> PdfDocument {
        try RedactionKit.page("/Fm1 Do BT /F1 12 Tf 50 700 Td (secret) Tj ET", "/XObject <</Fm1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox \(box) /Filter /FlateDecode", "this is not deflate data")
        }
    }

    func test_formThatCannotBeReadMakesThePagePictureWhereverItIs() throws {
        for box in ["[0 0 600 800]", "[0 0 10 10]"] {
            let document = try unreadable(box)
            try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, mark)], "secret", "this is not deflate data")
        }
    }

    func test_verifyDoesNotCallAPageItCannotFollowClean() throws {
        let document = try chain(22)
        let verification = PdfRedactor.verify(try document.saveRewrite(), [RedactionMark.fromRect(0, mark)], [])
        XCTAssertFalse(verification.isClean)
        XCTAssertEqual(verification.problems.count, 1)
        XCTAssertTrue(verification.problems.first?.contains("Page 1 could not be followed") ?? false)
    }

    func test_verifyChecksEveryRemovedStringNotTheFirstFiveHundred() throws {
        let document = try RedactionKit.page("/Span <</ActualText (ZQXLASTNEEDLE)>> BDC EMC")
        let removed = (0..<600).map { "needle number \($0)" } + ["ZQXLASTNEEDLE"]
        let verification = PdfRedactor.verify(try document.saveRewrite(), [], removed)
        XCTAssertFalse(verification.isClean)
    }

    func test_verifySaysSoWhenThereAreMoreStringsThanItChecks() throws {
        let document = try RedactionKit.page("BT ET")
        let removed = (0..<50_001).map { "needle number \($0)" }
        let verification = PdfRedactor.verify(try document.saveRewrite(), [], removed)
        XCTAssertTrue(verification.problems.contains { $0.hasPrefix("Not every removed string") })
    }
}
