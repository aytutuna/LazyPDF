import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/StructureLoopTests.cs: the same case.

final class StructureLoopTests: XCTestCase {
    func test_an_array_of_kids_that_contains_itself_is_read_without_overflowing_the_stack() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(6, "<</Type /StructTreeRoot /K 7 0 R>>")
        pdf.obj(7, "[7 0 R]")
        let document = try PdfDocument.open(pdf.finish())

        let tree = StructureTree.read(document)

        XCTAssertNotNil(tree)
        XCTAssertEqual(tree?.isTruncated, true)
    }
}
