#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureStampTests.cs: the same cases. A document time stamp is the
// one signature allowed after a certification that permits no change, and only when it shows nothing and does nothing.

final class SignatureStampTests: XCTestCase {
    // A time stamp field and its widget added to the empty form of SignatureOverlapTests.formPdf, the widget written as given.
    private func addStamp(_ widget: String) throws -> SignatureChangeReport {
        let before = SignatureOverlapTests.formPdf().finish()
        let after = try SignatureTestHelpers.appendRaw(before, [
            (3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [32 0 R]>>"),
            (9, "<</Fields [30 0 R]>>"),
            (30, "<</FT /Sig /T (Late) /Kids [32 0 R] /V 31 0 R>>"),
            (31, SignatureOverlapTests.stampDict),
            (32, widget),
            (33, SignatureRawKit.streamBody(SignatureRawKit.evil, SignatureRawKit.form)),
        ])
        return try SignatureOverlapTests.compare(before, after, 1, 31)
    }

    func test_aWidgetWithAnEmptyRectangleAndNothingElseIsAllowed() throws {
        let report = try addStamp("<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect [0 0 0 0] /P 3 0 R /AP <</N 33 0 R>>>>")

        XCTAssertTrue(report.allAllowed)
    }

    func test_aRectangleThatIsNotFourNumbersCountsAsAnArea() throws {
        for rect in ["[null 0 300 400]", "[/a 0 300 400]", "[0 0 300 (x)]", "[77 0 R 0 300 400]", "[0 0 0]", "77 0 R"] {
            let report = try addStamp("<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect \(rect) /P 3 0 R /AP <</N 33 0 R>>>>")

            XCTAssertFalse(report.allAllowed, rect)
        }
    }

    func test_aRectangleWrittenTwiceCountsAsAnArea() throws {
        let report = try addStamp("<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect [0 0 300 400] /Rect [0 0 0 0] /P 3 0 R>>")

        XCTAssertFalse(report.allAllowed)
    }

    func test_aWidgetWithAnActionIsNotAllowed() throws {
        for action in ["/A <</S /JavaScript /JS (x)>>", "/AA <</PO <</S /JavaScript /JS (x)>>>>"] {
            let report = try addStamp("<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect [0 0 0 0] /P 3 0 R \(action)>>")

            XCTAssertFalse(report.allAllowed, action)
        }
    }
}
#endif
