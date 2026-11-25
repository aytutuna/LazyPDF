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

    // Each object holds arrays nested as deep as the lexer allows and ends in a reference to the next, so only the count of levels bounds the stack.
    func test_arrays_nested_inside_each_object_and_chained_across_objects_do_not_overflow_the_stack() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(6, "<</Type /StructTreeRoot /K 10 0 R>>")
        for n in 10..<40 { pdf.obj(n, String(repeating: "[", count: 190) + "\(n + 1) 0 R" + String(repeating: "]", count: 190)) }
        let document = try PdfDocument.open(pdf.finish())

        let tree = StructureTree.read(document)

        XCTAssertNotNil(tree)
        XCTAssertEqual(tree?.isTruncated, true)
    }

    func test_empty_arrays_count_against_the_node_limit() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(6, "<</Type /StructTreeRoot /K 7 0 R>>")
        pdf.obj(7, "[" + String(repeating: "[]", count: 1_000_001) + "]")
        let document = try PdfDocument.open(pdf.finish())

        let tree = StructureTree.read(document)

        XCTAssertNotNil(tree)
        XCTAssertEqual(tree?.isTruncated, true)
    }
}
