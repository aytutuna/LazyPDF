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
        try f.marker.add(.rectangle, 0, [pt(60, 80), pt(260, 140)], red)
        let note = try f.marker.add(.note, 0, [pt(300, 100)], red, "Check the total")
        _ = try PdfComments.reply(f.document, note, "Done", "Can", DateTimeOffset(2026, 11, 5, 9, 0, 0))
        try f.tab.commit("Marks")
        return f
    }

    func test_exportedCommentsComeBackIntoAnotherCopy() throws {
        for xfdf in [false, true] {
            let source = try withMarks()
            let target = try CommentFixture()

            let data = try Exchange.export(source.document, "a.pdf", xfdf: xfdf).data
            let result = try Exchange.import(target.document, data, xfdf: xfdf, FakeFonts())

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
        let data = try Exchange.export(source.document, nil, xfdf: false).data
        _ = try Exchange.import(target.document, data, xfdf: false, FakeFonts())
        try target.tab.commit("Import comments")

        let again = try Exchange.import(target.document, data, xfdf: false, FakeFonts())

        XCTAssertEqual(again.imported, 0)
    }

    func test_aFileThatIsNotACommentFileIsRefused() throws {
        for xfdf in [false, true] {
            let f = try CommentFixture()

            XCTAssertThrowsError(try Exchange.import(f.document, [1, 2, 3, 4], xfdf: xfdf, FakeFonts())) {
                XCTAssertTrue($0 is PdfReadException)
            }
        }
    }

    func test_theExtensionSaysWhichFormat() {
        XCTAssertTrue(Exchange.isXfdf("notes.xfdf"))
        XCTAssertTrue(Exchange.isXfdf("NOTES.XFDF"))
        XCTAssertFalse(Exchange.isXfdf("notes.fdf"))
        XCTAssertFalse(Exchange.isXfdf("notes"))
    }

    func test_flatteningBurnsTheMarksIntoThePagesAndOneUndoBringsThemBack() throws {
        let f = try withMarks()
        let before = Exchange.flattenable(f.document)

        let burned = try Exchange.flatten(f.document, CancelToken())
        try f.tab.commit("Flatten comments")

        XCTAssertEqual(burned, before)
        XCTAssertGreaterThanOrEqual(burned, 2)
        XCTAssertTrue(f.marks().isEmpty)
        XCTAssertEqual(Exchange.flattenable(f.document), 0)
        XCTAssertTrue(try f.tab.undo())
        XCTAssertEqual(Exchange.flattenable(f.document), before)
    }

    func test_aFileWithNoMarksHasNothingToFlatten() throws {
        let f = try CommentFixture()

        XCTAssertEqual(Exchange.flattenable(f.document), 0)
        XCTAssertEqual(try Exchange.flatten(f.document, CancelToken()), 0)
    }
}
