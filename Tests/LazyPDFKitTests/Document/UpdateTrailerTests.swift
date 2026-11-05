import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/UpdateTrailerTests.cs: the same cases.

final class UpdateTrailerTests: XCTestCase {
    func test_anInfoTakenOutStaysOutAfterAReopen() throws {
        for kind in ["table", "stream", "hybrid"] {
            let document = try PdfDocument.open(SaveFixtures.make(kind))
            XCTAssertNotNil(document.info, kind)
            document.trailer.remove("Info")
            let reopened = try PdfDocument.open(document.saveIncremental())
            XCTAssertNil(reopened.info, kind)

            reopened.catalog["Touched"] = PdfNumber(1)
            XCTAssertNil(try PdfDocument.open(reopened.saveIncremental()).info, kind)
        }
    }

    func test_aSizeBeyondTheNumberLimitIsNotTakenAtItsWord() throws {
        let file = try SaveFixtures.make("stream")
        let huge = TestPdf.replace(file, "/Size 9 ", "/Size 9999999 /Index [0 9] ")
        let document = try PdfDocument.open(huge)
        XCTAssertFalse(document.xrefRebuilt)
        XCTAssertLessThanOrEqual(document.nextObjectNumber, 10)
        document.info?["Author"] = PdfString(bytes: TestPdf.latin("Me"), isHex: false)
        XCTAssertFalse(try PdfDocument.open(document.saveIncremental()).xrefRebuilt)
        _ = try document.add(PdfDictionary())
    }
}
