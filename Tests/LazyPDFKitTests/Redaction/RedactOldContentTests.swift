import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactOldContentTests.cs: the same cases. The page content that was replaced
// must not stay reachable under another key.

final class RedactOldContentTests: XCTestCase {
    private let near = PdfRect(90, 90, 200, 120)

    func test_otherKeyNamingTheReplacedContentDoesNotKeepIt() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 100 Td [(ZQX) -1 (CYCLE)] TJ ET")
        document.pages[0].dictionary["Keep"] = PdfReference(4, 0)
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, near)])
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQX"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "CYCLE"))
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
    }

    func test_contentOfAnotherPageThatStillUsesItStays() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 6 0 R>>>>>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 6 0 R>>>>>>")
        pdf.stream(5, "", "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET")
        pdf.obj(6, RedactionKit.helvetica)
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, near)])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output, 0), "")
        XCTAssertEqual(RedactionKit.text(output, 1), "ZQXCYCLE")
    }

    func test_referenceNestedDeeperThanThirtyLevelsIsTakenOutToo() throws {
        let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
        let document = try RedactionKit.page("q 100 0 0 100 100 100 cm /Im1 Do Q", "/XObject <</Im1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8", pixels)
        }
        var deep: PdfObject = PdfReference(6, 0)
        for _ in 0..<40 { deep = PdfArray([deep]) }
        document.pages[0].dictionary["Keep"] = deep
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(90, 90, 210, 210))])
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }
}
