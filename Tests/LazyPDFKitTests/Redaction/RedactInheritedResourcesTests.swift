import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactInheritedResourcesTests.cs: the same case.

final class RedactInheritedResourcesTests: XCTestCase {
    private let pixels = "ZQXINHERITED012"

    func test_resourcesTakenFromThePageTreeLeaveNoCopyOfTheCutImageBehind() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> /XObject <</Im1 6 0 R>>>>>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 7 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 8 0 R>>")
        pdf.obj(5, ContentTestPdf.helvetica)
        pdf.stream(6, "/Type /XObject /Subtype /Image /Width 5 /Height 3 /ColorSpace /DeviceGray /BitsPerComponent 8", pixels)
        pdf.stream(7, "", "q 150 0 0 90 100 100 cm /Im1 Do Q BT /F1 12 Tf 100 300 Td (first) Tj ET")
        pdf.stream(8, "", "BT /F1 12 Tf 100 300 Td (second) Tj ET")
        let document = try PdfDocument.open(pdf.finish())

        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, PdfRect(90, 90, 260, 200))])
        let output = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, pixels))
        let images = RedactionKit.images(output)
        XCTAssertEqual(images.count, 1)
        for b in try output.data(try XCTUnwrap(images.first?.stream)) { XCTAssertEqual(b, 0) }
        XCTAssertEqual(RedactionKit.text(output, 0), "first")
        XCTAssertEqual(RedactionKit.text(output, 1), "second")
    }
}
