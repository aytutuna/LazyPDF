import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageDeleteTests.cs: the same cases. The PdfPig read in Reopen has no twin.

final class PageDeleteTests: XCTestCase {
    func test_deletedPagesAreGoneAndTheRestKeepsItsOrder() throws {
        let document = try PageTestFiles.open(5)
        try PageOperations.delete(document, [1, 3])
        XCTAssertEqual(PageTestFiles.order(document), [1, 3, 5])
        XCTAssertEqual(try PageTestFiles.reopen(document), ["Page 1", "Page 3", "Page 5"])
        XCTAssertEqual(document.integer(document.dict(document.catalog, "Pages"), "Count"), 3)
    }

    func test_theObjectsOfDeletedPagesAreFreed() throws {
        let document = try PageTestFiles.open(3)
        try PageOperations.delete(document, [0])
        XCTAssertNil(document.get(PageTestFiles.pageObject(0)))
        XCTAssertNotNil(document.get(PageTestFiles.pageObject(1)))
    }

    func test_aRepeatedIndexDeletesOnePage() throws {
        let document = try PageTestFiles.open(3)
        try PageOperations.delete(document, [1, 1])
        XCTAssertEqual(PageTestFiles.order(document), [1, 3])
    }

    func test_noPagesAtAllIsNotADocument() throws {
        let document = try PageTestFiles.open(2)
        XCTAssertThrowsError(try PageOperations.delete(document, [0, 1]))
        XCTAssertEqual(document.pages.count, 2)
    }

    func test_deletingNothingChangesNothing() throws {
        let session = try PdfEditSession.open(PageTestFiles.make(2))
        try PageOperations.delete(session.document, [])
        XCTAssertFalse(try session.commit("Delete"))
    }

    func test_aDeleteIsOneUndoStep() throws {
        let session = try PdfEditSession.open(PageTestFiles.make(4))
        try PageOperations.delete(session.document, [0, 2])
        let reopened = try PageTestFiles.commit(session, "Delete pages")
        XCTAssertEqual(PageTestFiles.order(reopened), [2, 4])
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(PageTestFiles.order(session.document), [1, 2, 3, 4])
        XCTAssertTrue(try session.redo())
        XCTAssertEqual(PageTestFiles.order(session.document), [2, 4])
    }

    func test_pagesInANestedTreeAreDeletedFromTheirNodes() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 3 /MediaBox [0 0 100 100]>>")
            .obj(3, "<</Type /Pages /Parent 2 0 R /Kids [5 0 R 6 0 R] /Count 2 /Rotate 90>>")
            .obj(4, "<</Type /Pages /Parent 2 0 R /Kids [7 0 R] /Count 1>>")
            .obj(5, "<</Type /Page /Parent 3 0 R /Contents 8 0 R>>")
            .obj(6, "<</Type /Page /Parent 3 0 R /Contents 9 0 R>>")
            .obj(7, "<</Type /Page /Parent 4 0 R /Contents 10 0 R>>")
            .stream(8, "", "(Page 1)").stream(9, "", "(Page 2)").stream(10, "", "(Page 3)")
        let document = try PdfDocument.open(pdf.finish())
        try PageOperations.delete(document, [0])
        let again = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(PageTestFiles.order(again), [2, 3])
        XCTAssertEqual(again.pages.map { $0.rotate }, [90, 0])
        XCTAssertEqual(again.repairs, [])
    }

    func test_aBeadThatIsAKeptPageIsNotDeletedWithTheThread() throws {
        let free = PageTestFiles.free(3)
        let document = try PageTestFiles.open(3, "/Threads [\(free) 0 R]", pageExtra: { $0 == 1 ? "/P \(PageTestFiles.pageObject(0)) 0 R" : "" },
                                              add: { $0.obj(free, "<</F \(PageTestFiles.pageObject(1)) 0 R>>") })
        try PageOperations.delete(document, [0])
        XCTAssertEqual(PageTestFiles.order(document), [2, 3])
    }
}
