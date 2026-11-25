import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/standards/PdfARowsTests.cs: the PDF/A panel's rows, and the words after a check and a
// conversion, against the engine's validator and converter.

final class PdfARowsTests: XCTestCase {
    private let march = DateTimeOffset(2026, 3, 1, 9, 0, 0)

    func test_issuesWithTheSameRuleAndSentenceMakeOneRow() {
        let rows = IssueRow.group([
            PdfAIssue("6.2.4.3", PdfAText.pageName(2), "A colour has no profile."),
            PdfAIssue("6.2.4.3", PdfAText.pageName(5), "A colour has no profile."),
            PdfAIssue("6.2.4.3", PdfAText.pageName(2), "A colour has no profile."),
            PdfAIssue("6.3.4", PdfAText.fontName("ABCDEF+Arial"), "The font is not embedded."),
        ])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].message, "A colour has no profile.")
        XCTAssertEqual(rows[0].place, "Page 2, and 2 more")
        XCTAssertEqual(rows[0].clause, "ISO 19005 clause 6.2.4.3")
        XCTAssertEqual(rows[1].place, "Font ABCDEF+Arial")
    }

    func test_onlyPlacesThatNameAPageCanBeVisitedAndTheyComeInTurn() {
        let rows = IssueRow.group([
            PdfAIssue("6.5.3", PdfAText.annotationName(4, 1), "An annotation has no appearance."),
            PdfAIssue("6.5.3", PdfAText.pageName(2), "An annotation has no appearance."),
            PdfAIssue("6.5.3", PdfAText.catalog, "An annotation has no appearance."),
            PdfAIssue("6.1.3", PdfAText.trailer, "The trailer has no /ID."),
        ])

        let annotation = rows[0]
        XCTAssertTrue(annotation.hasPlaces)
        XCTAssertEqual(annotation.placeText, "Go to page 2")
        XCTAssertEqual(annotation.nextPage(), 1)
        XCTAssertEqual(annotation.nextPage(), 3)
        XCTAssertEqual(annotation.nextPage(), 1)
        XCTAssertFalse(rows[1].hasPlaces)
    }

    func test_aRealCheckListsRulesInPlainWords() throws {
        let report = PdfAValidator.validate(try PdfDocument.open(Pdfs.text()), .a2b)

        let rows = IssueRow.group(report.issues)

        XCTAssertFalse(report.isValid)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { !$0.message.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func test_aConvertedFileIsStatedAsPassingTheChecksNeverAsConforming() throws {
        let made = try PdfAConverter(FakeFonts()).convert(Pdfs.text(), .a2b, march)

        let bytes = try XCTUnwrap(made.bytes)
        let report = PdfAValidator.validate(try PdfDocument.open(bytes), .a2b)
        let text = StandardsText.convertedText(made, .a2b)

        if made.isClean {
            XCTAssertTrue(report.isValid)
            XCTAssertTrue(text.contains("passes Lazy PDF's checks for PDF/A-2b"))
        } else {
            XCTAssertTrue(text.contains("still breaks"))
        }
        XCTAssertFalse(text.lowercased().contains("conform"))
        XCTAssertFalse(text.lowercased().contains("compliant"))
    }

    func test_aFileWithoutOwnerRightsIsRefusedWithTheReasonTheEngineGives() throws {
        let refused = try PdfAConverter(FakeFonts()).convert(Pdfs.restricted(.print), .a2b, DateTimeOffset(1970, 1, 1, 0, 0, 0))

        XCTAssertNil(refused.bytes)
        XCTAssertFalse((refused.refusal ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func test_everyLevelHasAWordForWhatItIsFor() {
        for level in StandardsModel.levels {
            XCTAssertFalse(StandardsText.describe(level).trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
