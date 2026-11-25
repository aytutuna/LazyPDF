import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/CommentListTests.cs: the same cases.

final class CommentListTests: XCTestCase {
    private let day = DateTimeOffset(2026, 3, 1, 9, 0, 0)

    private func later(_ hours: Int) -> DateTimeOffset {
        DateTimeOffset(2026, 3, 1, 9 + hours, 0, 0)
    }

    private func sample() throws -> (document: PdfDocument, low: PdfAnnotation, high: PdfAnnotation, onSecond: PdfAnnotation) {
        let document = try AnnotationFixtures.blank(2)
        let writer = PdfAnnotationWriter(document)
        let low = try writer.addNote(document.pages[0], PdfRect(50, 100, 70, 120), AnnotationInfo(author: "Zeynep", contents: "low on page one", date: later(2)))
        let high = try writer.addTextMarkup(document.pages[0], .highlight, [MarkupQuad.fromRect(PdfRect(50, 700, 150, 714))],
                                            info: AnnotationInfo(author: "ali", contents: "high on page one", date: later(1)))
        let onSecond = try writer.addSquare(document.pages[1], PdfRect(10, 10, 80, 80), info: AnnotationInfo(author: "Ali", contents: "box", date: day))
        return (document, low, high, onSecond)
    }

    func test_pageOrderReadsTopToBottom() throws {
        let (document, _, _, _) = try sample()
        let list = PdfComments.list(document)
        XCTAssertEqual(list.map { $0.text }, ["high on page one", "low on page one", "box"])
        XCTAssertEqual(list.map { $0.pageIndex }, [0, 0, 1])
        XCTAssertEqual(list.map { AnnotationText.kindName($0.type) }, ["Highlight", "Note", "Rectangle"])
    }

    func test_sortsByDateAuthorAndType() throws {
        let (document, _, _, _) = try sample()
        XCTAssertEqual(PdfComments.list(document, nil, .date).map { $0.text }, ["box", "high on page one", "low on page one"])
        XCTAssertEqual(PdfComments.list(document, nil, .date, descending: true).map { $0.text }, ["low on page one", "high on page one", "box"])
        XCTAssertEqual(Array(PdfComments.list(document, nil, .author, descending: true).map { $0.author }.prefix(1)), ["Zeynep"])
        XCTAssertEqual(PdfComments.list(document, nil, .author).map { $0.author }, ["ali", "Ali", "Zeynep"])
        XCTAssertEqual(PdfComments.list(document, nil, .type).map { AnnotationText.kindName($0.type) }, ["Highlight", "Note", "Rectangle"])
    }

    func test_filtersByAuthorTextPageAndType() throws {
        let (document, _, _, _) = try sample()
        XCTAssertEqual(PdfComments.list(document, CommentFilter(author: "ALI")).count, 2)
        XCTAssertEqual(PdfComments.list(document, CommentFilter(text: "LOW")).map { $0.text }, ["low on page one"])
        XCTAssertEqual(PdfComments.list(document, CommentFilter(pageIndex: 1)).map { $0.text }, ["box"])
        XCTAssertEqual(PdfComments.list(document, CommentFilter(types: [.highlight])).map { $0.text }, ["high on page one"])
        XCTAssertTrue(PdfComments.list(document, CommentFilter(text: "nothing like this")).isEmpty)
    }

    func test_linksWidgetsAndPopupsAreNotComments() throws {
        let document = try AnnotationFixtures.blank(1, { pdf in
            pdf.obj(20, "<</Subtype /Link /Rect [0 0 5 5]>>")
            pdf.obj(21, "<</Subtype /Widget /Rect [0 0 5 5]>>")
            pdf.obj(22, "<</Subtype /Popup /Rect [0 0 5 5]>>")
            pdf.obj(23, "<</Subtype /Text /Rect [0 0 5 5] /Contents (yes)>>")
        }, pageEntries: "/Annots [20 0 R 21 0 R 22 0 R 23 0 R]")
        let list = PdfComments.list(document)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.text, "yes")
    }

    func test_repliesJoinTheirThreadWhateverTheDepth() throws {
        let (document, low, _, _) = try sample()
        let first = try PdfComments.reply(document, low, "agreed", "Can", later(3))
        let second = try PdfComments.reply(document, first, "me too", "Deniz", later(4))
        XCTAssertEqual(first.inReplyTo, low.reference)
        XCTAssertEqual(first.replyType, "R")
        XCTAssertTrue(first.flags.contains(.hidden))
        XCTAssertEqual(second.inReplyTo, first.reference)

        let list = PdfComments.list(document)
        XCTAssertEqual(list.count, 3)
        let thread = try XCTUnwrap(list.first { $0.text == "low on page one" })
        XCTAssertEqual(thread.replies.map { $0.contents }, ["agreed", "me too"])
        XCTAssertEqual(thread.replies.map { $0.title }, ["Can", "Deniz"])
        XCTAssertEqual(PdfComments.list(document, CommentFilter(hasReplies: true)).count, 1)
        XCTAssertEqual(PdfComments.list(document, CommentFilter(author: "deniz")).count, 1)
        try AnnotationFixtures.reopen(document)
    }

    func test_statusFollowsTheLatestChange() throws {
        let (document, low, high, _) = try sample()
        for comment in PdfComments.list(document) { XCTAssertEqual(comment.status, ReviewStatus.none) }
        try PdfComments.setStatus(document, low, .accepted, "Can", later(5))
        let rejected = try PdfComments.setStatus(document, low, .rejected, "Deniz", later(6))
        try PdfComments.setStatus(document, high, .marked, "Can", day)

        XCTAssertEqual(PdfText.read(document, rejected.dictionary, "StateModel"), "Review")
        XCTAssertEqual(PdfText.read(document, rejected.dictionary, "State"), "Rejected")
        XCTAssertEqual(PdfComments.list(document).first { $0.text == "low on page one" }?.status, .rejected)
        XCTAssertEqual(PdfComments.list(document).first { $0.text == "high on page one" }?.status, .marked)
        XCTAssertEqual(PdfComments.list(document, CommentFilter(status: .rejected)).map { $0.text }, ["low on page one"])
        XCTAssertEqual(rejected.contents, "Rejected set by Deniz")

        let reopened = try AnnotationFixtures.reopen(document)
        XCTAssertEqual(PdfComments.list(reopened).first { $0.text == "low on page one" }?.status, .rejected)
    }

    func test_cancelledIsStoredWithTheSpecSpelling() throws {
        let (document, low, _, _) = try sample()
        let reply = try PdfComments.setStatus(document, low, .cancelled, "Can", day)
        XCTAssertEqual(PdfText.read(document, reply.dictionary, "State"), "Cancelled")
        let reopened = try AnnotationFixtures.reopen(document)
        XCTAssertEqual(PdfComments.list(reopened).first { $0.text == "low on page one" }?.status, .cancelled)
    }

    func test_markedModelUsesItsOwnName() throws {
        let (document, low, _, _) = try sample()
        let marked = try PdfComments.setStatus(document, low, .unmarked, "Can", day)
        XCTAssertEqual(PdfText.read(document, marked.dictionary, "StateModel"), "Marked")
        XCTAssertEqual(marked.state, .unmarked)
    }

    func test_replyNeedsAnIndirectAnnotationOnAPage() throws {
        let document = try AnnotationFixtures.blank(1, pageEntries: "/Annots [<</Subtype /Text /Rect [0 0 5 5]>>]")
        let direct = try XCTUnwrap(PdfAnnotations.read(document, document.pages[0]).first)
        XCTAssertThrowsError(try PdfComments.reply(document, direct, "x", "A", day)) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_aParentTooFarOutLeavesNoRoomForTheReply() throws {
        let document = try AnnotationFixtures.blank(1, { $0.obj(20, "<</Subtype /Text /Rect [1000000000000000000 1000000000000000000 2000000000000000000 2000000000000000000]>>") }, pageEntries: "/Annots [20 0 R]")
        let parent = try XCTUnwrap(PdfAnnotations.read(document, document.pages[0]).first)
        XCTAssertThrowsError(try PdfComments.reply(document, parent, "x", "A", day)) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_danglingReplyCountsAsAComment() throws {
        let document = try AnnotationFixtures.blank(1, { $0.obj(20, "<</Subtype /Text /Rect [0 0 5 5] /IRT 99 0 R /Contents (orphan)>>") }, pageEntries: "/Annots [20 0 R]")
        let list = PdfComments.list(document)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.text, "orphan")
    }

    func test_richTextOnlyCommentShowsPlainText() throws {
        let document = try AnnotationFixtures.blank(1, { $0.obj(20, "<</Subtype /FreeText /Rect [0 0 50 50] /RC (<body xmlns=\"http://www.w3.org/1999/xhtml\"><p>one</p><p>two</p></body>)>>") }, pageEntries: "/Annots [20 0 R]")
        XCTAssertEqual(PdfComments.list(document).first?.text, "one\ntwo")
    }
}
