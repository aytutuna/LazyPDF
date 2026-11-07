import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Comments panel: the list, its filters, answering a comment and the summary. Windows has no test of
// CommentsSidePanel; the cases are those its code handles.

@MainActor
final class CommentsModelTests: XCTestCase {
    private struct Rig {
        let model: CommentsModel
        let viewer: PanelViewer
        let tab: DocumentTab
        let host: RecordingHost
    }

    private func attached(signed: Bool = false, comments: Bool = true) throws -> Rig {
        let tab = try PanelPdfs.tab(PanelPdfs.full(signed: signed))
        if comments {
            try PanelPdfs.comment(tab, page: 0, author: "Ada", text: "Look")
            try PanelPdfs.comment(tab, page: 1, author: "Grace", text: "Check this")
        }
        let viewer = PanelViewer(tab)
        let host = RecordingHost()
        let model = CommentsModel()
        model.author = "Reviewer"
        model.attach(tab, viewer, host)
        return Rig(model: model, viewer: viewer, tab: tab, host: host)
    }

    func test_commentsAreGroupedByPageWithTheirTitleAndPlace() throws {
        let rig = try attached()

        XCTAssertEqual(rig.model.groups.map { $0.name }, ["Page 1", "Page 2"])
        let row = rig.model.groups[0].rows[0]
        XCTAssertEqual(row.title, "Note · Ada")
        XCTAssertEqual(row.text, "Look")
        XCTAssertEqual(row.location, "Page 1")
        XCTAssertEqual(row.summary, "Note · Ada, Page 1, Look")
    }

    func test_theHeadingsFollowTheGrouping() throws {
        let rig = try attached()

        rig.model.setGrouping(.author)
        XCTAssertEqual(rig.model.groups.map { $0.name }, ["Ada", "Grace"])
        rig.model.setGrouping(.type)
        XCTAssertEqual(rig.model.groups.map { $0.name }, ["Note"])
        XCTAssertEqual(rig.model.rows.count, 2)
    }

    func test_pageLabelsOfTheFileNameThePages() throws {
        let rig = try attached()
        let labelled = PanelViewer(rig.tab, labels: ["iv", "v"])
        rig.model.detach()
        rig.model.attach(rig.tab, labelled, rig.host)

        XCTAssertEqual(rig.model.groups.map { $0.name }, ["Page iv", "Page v"])
    }

    func test_typingInTheFilterNarrowsTheListOncePausedAndLooksAtAuthors() async throws {
        let rig = try attached()

        rig.model.setQuery("check")
        await settle { rig.model.rows.count == 1 }
        XCTAssertEqual(rig.model.rows[0].comment.author, "Grace")

        rig.model.setQuery("ADA")
        await settle { rig.model.rows.first?.comment.author == "Ada" && rig.model.rows.count == 1 }
        rig.model.setQuery("nobody")
        await settle { rig.model.isEmpty }
        XCTAssertEqual(rig.model.emptyText, "No comment matches.")
    }

    func test_aFileWithoutCommentsSaysSo() throws {
        let rig = try attached(comments: false)

        XCTAssertTrue(rig.model.isEmpty)
        XCTAssertEqual(rig.model.emptyText, "This file has no comments.")
    }

    func test_choosingACommentShowsItOnItsPage() throws {
        let rig = try attached()

        rig.model.go(rig.model.groups[1].rows[0])

        XCTAssertEqual(rig.viewer.sent, [1])
        XCTAssertEqual(rig.viewer.revealed.map { $0.page }, [1])
        XCTAssertGreaterThan(rig.viewer.revealed[0].area.width, 0)
    }

    func test_aReplyIsWrittenAndShownUnderTheComment() async throws {
        let rig = try attached()
        rig.model.select(rig.model.rows[0].id)
        XCTAssertTrue(rig.model.canAnswer)

        XCTAssertTrue(rig.model.reply("  Fixed  "))

        await settle { rig.model.replies == ["Reviewer: Fixed"] }
        XCTAssertTrue(rig.tab.isDirty)
        XCTAssertEqual(rig.model.selectedRow?.location, "Page 1 · 1 reply")
        XCTAssertTrue(rig.host.problems.isEmpty)
    }

    func test_aBlankReplyIsNotSent() throws {
        let rig = try attached()
        rig.model.select(rig.model.rows[0].id)
        let before = rig.tab.revision

        XCTAssertFalse(rig.model.reply("   "))

        XCTAssertEqual(rig.tab.revision, before)
    }

    func test_aStatusIsSetAndFilteredBy() async throws {
        let rig = try attached()
        rig.model.select(rig.model.rows[1].id)

        rig.model.setStatus(.accepted)

        await settle { rig.model.selectedRow?.comment.status == .accepted }
        XCTAssertEqual(rig.model.selectedRow?.location, "Page 2 · Accepted")
        rig.model.setStatusFilter(.accepted)
        XCTAssertEqual(rig.model.rows.count, 1)
        rig.model.setStatusFilter(.rejected)
        XCTAssertTrue(rig.model.isEmpty)
        rig.model.setStatusFilter(nil)
        XCTAssertEqual(rig.model.rows.count, 2)
    }

    func test_aSignedFileAsksBeforeAReplyBreaksItsSignatures() async throws {
        let rig = try attached(signed: true)
        rig.model.select(rig.model.rows[0].id)
        let before = rig.tab.revision

        XCTAssertFalse(rig.model.reply("Fixed"))

        XCTAssertEqual(rig.tab.revision, before)
        let notice = try XCTUnwrap(rig.host.notices.first)
        XCTAssertEqual(notice.title, "Check before going on")
        XCTAssertEqual(notice.text, "This file is signed, so changing it breaks the signatures.")
        XCTAssertEqual(notice.action?.text, "Go on anyway")

        notice.action?.run()
        await settle { rig.tab.revision == before + 1 }
    }

    func test_nothingIsWrittenWhileAToolHoldsTheDocument() throws {
        let rig = try attached()
        rig.model.select(rig.model.rows[0].id)
        rig.model.isBlocked = { true }
        let before = rig.tab.revision

        XCTAssertFalse(rig.model.reply("Fixed"))
        rig.model.setStatus(.rejected)

        XCTAssertEqual(rig.tab.revision, before)
    }

    func test_theSummaryListsTheCommentsOnShow() throws {
        let rig = try attached()

        let text = try XCTUnwrap(rig.model.summaryText())

        XCTAssertTrue(text.hasPrefix("a.pdf\n2 comments\n\nPage 1, Note, Ada, 2026-03-01\n  Look\n"))
        XCTAssertTrue(text.contains("\nPage 2, Note, Grace, 2026-03-01\n  Check this\n"))
        XCTAssertEqual(rig.model.summaryName, "a Comments")
    }

    func test_withoutCommentsThereIsNothingToExport() throws {
        let rig = try attached(comments: false)

        XCTAssertNil(rig.model.summaryText())
        XCTAssertEqual(rig.host.statuses, ["No comments to export."])
    }

    func test_theOutcomeOfSavingTheSummaryIsToldToTheWindow() throws {
        let rig = try attached()

        rig.model.summarySaved(.success(URL(fileURLWithPath: "/tmp/a.txt")))
        rig.model.summarySaved(.failure(CocoaError(.fileWriteUnknown)))

        XCTAssertEqual(rig.host.statuses, ["Summary saved."])
        XCTAssertEqual(rig.host.problems.first?.title, "Not saved")
    }
}

final class CommentSummaryTests: XCTestCase {
    func test_repliesAndStatusFollowTheirComment() throws {
        let session = try PdfEditSession.open(Pdfs.text())
        let when = DateTimeOffset(2026, 3, 1, 0, 0, 0)
        let note = try PdfAnnotationWriter(session.document).addNote(session.document.pages[0], PdfRect(10, 10, 30, 30),
                                                                    AnnotationInfo(author: "Ada", contents: "Look\nhere", date: when))
        _ = try PdfComments.reply(session.document, note, "Done", "Grace", when)
        _ = try PdfComments.setStatus(session.document, note, .accepted, "Grace", when)
        _ = try session.commit("Review")

        let comments = PdfComments.list(session.document)
        let text = CommentSummary.text("a.pdf", comments, { String($0 + 1) })

        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(text, "a.pdf\n1 comment\n\nPage 1, Note, Ada, 2026-03-01\n  Look here\n  Status: Accepted\n  Reply from Grace: Done\n")
    }
}
