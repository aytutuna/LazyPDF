import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/comment/ExchangeTests.cs: comments out to FDF and XFDF and back in, and flattening.
// Left out: the plain text summary, the list row and the filtering test, which are the Comments side panel's (CommentsModelTests
// and the engine's own tests of PdfComments).

@MainActor
final class ExchangeTests: XCTestCase {
    private func withMarks() throws -> CommentFixture {
        let f = try CommentFixture()
        try f.marker.add(.rectangle, 0, [markPt(60, 80), markPt(260, 140)], markRed)
        let note = try f.marker.add(.note, 0, [markPt(300, 100)], markRed, "Check the total")
        _ = try PdfComments.reply(f.document, note, "Done", "Can", DateTimeOffset(2026, 11, 5, 9, 0, 0))
        try f.tab.commit("Marks")
        return f
    }

    func test_exportedCommentsComeBackIntoAnotherCopy() throws {
        for xfdf in [false, true] {
            let source = try withMarks()
            let target = try CommentFixture()

            let data = try CommentExchange.export(source.document, "a.pdf", xfdf: xfdf).data
            let result = try CommentExchange.import(target.document, data, xfdf: xfdf, FakeFonts())

            XCTAssertGreaterThanOrEqual(result.imported, 2)
            XCTAssertEqual(result.skipped, 0)
            try target.tab.commit("Import comments")
            let comments = PdfComments.list(target.document)
            XCTAssertEqual(comments.count, 2)
            XCTAssertTrue(comments.contains { $0.text == "Check the total" && $0.replies.count == 1 })
        }
    }

    func test_importingTheSameFileTwiceAddsNothingTheSecondTime() throws {
        let source = try withMarks()
        let target = try CommentFixture()
        let data = try CommentExchange.export(source.document, nil, xfdf: false).data
        _ = try CommentExchange.import(target.document, data, xfdf: false, FakeFonts())
        try target.tab.commit("Import comments")

        let again = try CommentExchange.import(target.document, data, xfdf: false, FakeFonts())

        XCTAssertEqual(again.imported, 0)
    }

    func test_aFileThatIsNotACommentFileIsRefused() throws {
        for xfdf in [false, true] {
            let f = try CommentFixture()

            XCTAssertThrowsError(try CommentExchange.import(f.document, [1, 2, 3, 4], xfdf: xfdf, FakeFonts())) {
                XCTAssertTrue($0 is PdfReadException)
            }
        }
    }

    func test_theExtensionSaysWhichFormat() {
        XCTAssertTrue(CommentExchange.isXfdf("notes.xfdf"))
        XCTAssertTrue(CommentExchange.isXfdf("NOTES.XFDF"))
        XCTAssertFalse(CommentExchange.isXfdf("notes.fdf"))
        XCTAssertFalse(CommentExchange.isXfdf("notes"))
    }

    func test_flatteningBurnsTheMarksIntoThePagesAndOneUndoBringsThemBack() throws {
        let f = try withMarks()
        let before = CommentExchange.flattenable(f.document)

        let burned = try CommentExchange.flatten(f.document, CancelToken())
        try f.tab.commit("Flatten comments")

        XCTAssertEqual(burned, before)
        XCTAssertGreaterThanOrEqual(burned, 2)
        XCTAssertTrue(f.marks().isEmpty)
        XCTAssertEqual(CommentExchange.flattenable(f.document), 0)
        XCTAssertTrue(try f.tab.undo())
        XCTAssertEqual(CommentExchange.flattenable(f.document), before)
    }

    func test_aFileWithNoMarksHasNothingToFlatten() throws {
        let f = try CommentFixture()

        XCTAssertEqual(CommentExchange.flattenable(f.document), 0)
        XCTAssertEqual(try CommentExchange.flatten(f.document, CancelToken()), 0)
    }
}
