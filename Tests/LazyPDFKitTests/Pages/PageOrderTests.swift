import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageOrderTests.cs: the same cases, except AnOrderThatIsNotAPermutationIsRefused and
// MovingBeyondTheEndIsRefused, whose ArgumentException and ArgumentOutOfRangeException are preconditions in Swift and cannot
// be caught.

final class PageOrderTests: XCTestCase {
    func test_reorderPutsThePageAtTheOldIndexFirst() throws {
        let document = try PageTestFiles.open(4)
        try PageOperations.reorder(document, [3, 0, 2, 1])
        XCTAssertEqual(PageTestFiles.order(document), [4, 1, 3, 2])
        XCTAssertEqual(PageTestFiles.order(try PdfDocument.open(try document.saveRewrite())), [4, 1, 3, 2])
    }

    func test_theIdentityOrderChangesNothing() throws {
        let session = try PdfEditSession.open(PageTestFiles.make(3))
        try PageOperations.reorder(session.document, [0, 1, 2])
        XCTAssertFalse(try session.commit("Reorder"))
    }

    func test_moveKeepsTheMovedPagesInTheirOwnOrder() throws {
        let cases: [([Int], Int, [Int])] = [
            ([3], 0, [4, 1, 2, 3, 5]),
            ([0], 5, [2, 3, 4, 5, 1]),
            ([0], 3, [2, 3, 1, 4, 5]),
            ([1, 2], 5, [1, 4, 5, 2, 3]),
            ([4, 3], 1, [1, 4, 5, 2, 3]),
            ([2], 2, [1, 2, 3, 4, 5]),
        ]
        for (pages, before, expected) in cases {
            let document = try PageTestFiles.open(5)
            try PageOperations.move(document, pages, before)
            XCTAssertEqual(PageTestFiles.order(document), expected, "\(pages) before \(before)")
        }
    }

    func test_pagesTakeWhatTheirOldNodesGaveBeforeTheyMove() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 100 100]>>")
            .obj(3, "<</Type /Pages /Parent 2 0 R /Kids [5 0 R] /Count 1 /Rotate 90 /Resources <</Font <<>>>>>>")
            .obj(4, "<</Type /Pages /Parent 2 0 R /Kids [6 0 R] /Count 1 /CropBox [0 0 50 50]>>")
            .obj(5, "<</Type /Page /Parent 3 0 R>>")
            .obj(6, "<</Type /Page /Parent 4 0 R>>")
        let document = try PdfDocument.open(pdf.finish())
        try PageOperations.reorder(document, [1, 0])
        let again = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(again.pages.map { $0.rotate }, [0, 90])
        XCTAssertEqual(again.pages[0].cropBox, PdfRect(0, 0, 50, 50))
        XCTAssertNotNil(again.pages[1].resources)
        XCTAssertEqual(again.pages[0].mediaBox, PdfRect(0, 0, 100, 100))
    }

    func test_aBigTreeIsLaidOutEvenAndEveryPageNamesItsNode() throws {
        let document = try PageTestFiles.open(1100)
        try PageOperations.reorder(document, Array((0..<1100).reversed()))
        let root = try XCTUnwrap(document.dict(document.catalog, "Pages"))
        XCTAssertLessThanOrEqual(try XCTUnwrap(document.array(root, "Kids")).items.count, 32)
        XCTAssertEqual(document.integer(root, "Count"), 1100)
        var deepest = 0
        for page in document.pages {
            var depth = 0
            var node = document.dict(page.dictionary, "Parent")
            while let current = node {
                depth += 1
                XCTAssertLessThanOrEqual(try XCTUnwrap(document.array(current, "Kids")).items.count, 32)
                node = document.dict(current, "Parent")
            }
            deepest = max(deepest, depth)
        }
        XCTAssertEqual(deepest, 3)
        XCTAssertEqual(PageTestFiles.order(document), Array((1...1100).reversed()))
        XCTAssertEqual(try PdfDocument.open(try document.saveRewrite()).pages.count, 1100)
    }

    func test_anEditNearTheEndOfABigFileRewritesFewObjects() throws {
        let session = try PdfEditSession.open(try PdfDocument.open(PageTestFiles.make(1100)).saveRewrite())
        try PageOperations.reorder(session.document, Array((0..<1100).reversed()))
        _ = try session.commit("Reverse")
        let before = session.current.count
        let document = session.document
        try PageOperations.delete(document, [1099])
        XCTAssertTrue(try session.commit("Delete"))
        XCTAssertLessThan(session.current.count - before, 40_000, "\(session.current.count - before) bytes")
        XCTAssertEqual(session.document.pages.count, 1099)
    }

    func test_aRepairedTreeIsLaidOutAgainWhateverWasWrongWithIt() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 2 0 R 99 0 R] /Count 7 /MediaBox [0 0 100 100]>>")
            .obj(3, "<</Type /Page /Contents 5 0 R>>")
            .obj(4, "<</Type /Page /Parent 77 0 R /Contents 6 0 R>>")
            .stream(5, "", "BT (Page 1) Tj ET")
            .stream(6, "", "BT (Page 2) Tj ET")
        let document = try PdfDocument.open(pdf.finish())
        try PageOperations.reorder(document, [1, 0])
        let again = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(PageTestFiles.order(again), [2, 1])
        XCTAssertEqual(again.integer(again.dict(again.catalog, "Pages"), "Count"), 2)
    }
}
