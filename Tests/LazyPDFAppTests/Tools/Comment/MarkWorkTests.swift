import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// What the Windows window and the Comments side panel do with MarkWork.Running, the commit that tolerates a file that will
// not take a change, and the long change off the main actor. Windows has no test of MarkWork itself.

@MainActor
final class MarkWorkTests: XCTestCase {
    override func tearDown() async throws {
        MarkWork.shared.running = false
    }

    func test_aChangeThatIsRunningBlocksTheWindowAndHoldsTheDocument() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        XCTAssertFalse(f.vm.isBlocked)
        XCTAssertFalse(f.vm.isDocumentBusy)

        MarkWork.shared.running = true

        XCTAssertTrue(f.vm.isBlocked)
        XCTAssertTrue(f.vm.isDocumentBusy)
        MarkWork.shared.running = false
        XCTAssertFalse(f.vm.isBlocked)
    }

    func test_theCommentsPanelAnswersNothingWhileAChangeIsRunning() async throws {
        let tab = try PanelPdfs.tab(PanelPdfs.full())
        try PanelPdfs.comment(tab)
        let model = CommentsModel()
        model.attach(tab, PanelViewer(tab), RecordingHost())
        model.select(model.rows[0].id)
        let before = tab.revision

        MarkWork.shared.running = true
        XCTAssertFalse(model.reply("Fixed"))
        model.setStatus(.rejected)
        MarkWork.shared.running = false

        XCTAssertEqual(tab.revision, before)
        XCTAssertTrue(model.reply("Fixed"))
    }

    func test_aSignedFileGetsACautionAndACertifiedOneAStrongerOne() async throws {
        let plain = try PdfDocument.open(Pdfs.text())
        let signed = try PdfDocument.open(Pdfs.signed(certified: false))
        let certified = try PdfDocument.open(Pdfs.signed(certified: true))

        XCTAssertNil(MarkWork.caution(plain))
        XCTAssertEqual(MarkWork.caution(signed), "This file is signed, so changing it breaks the signatures.")
        XCTAssertEqual(MarkWork.caution(certified), "This file is certified, so changing it makes viewers report it as altered.")
    }

    func test_aChangeToASignedFileIsHeldBackUntilThePersonGoesOn() async throws {
        let rig = try ToolRig(try Pdfs.signed(certified: false))
        var ran = 0

        XCTAssertTrue(MarkWork.cautioned(rig.tab, rig.host) { ran += 1 })
        XCTAssertEqual(rig.host.notices.map(\.title), ["Check before going on"])
        XCTAssertEqual(ran, 0)
        rig.host.notices[0].action?.run()

        XCTAssertEqual(ran, 1)
        let plain = try ToolRig()
        XCTAssertFalse(MarkWork.cautioned(plain.tab, plain.host) { ran += 1 })
    }

    func test_aCommitWithNothingChangedIsFalse() async throws {
        let rig = try ToolRig()

        XCTAssertFalse(try MarkWork.commit(rig.tab, rig.host, "Nothing"))
        XCTAssertTrue(rig.host.problems.isEmpty)
    }

    func test_aChangeOffTheMainActorGivesItsResultAndLeavesTheCommitToTheCaller() async throws {
        let f = try CommentFixture()
        let host = MarkHost()
        let marker = f.marker

        let made = try await MarkWork.shared.change(f.tab, host, "Adding", isCurrent: { true }) { _, _ in
            try marker.add(.rectangle, 0, [markPt(60, 80), markPt(260, 140)], markRed).type
        }

        XCTAssertEqual(made, .square)
        XCTAssertFalse(MarkWork.shared.running)
        XCTAssertEqual(host.runningInside, [true])
        XCTAssertEqual(f.marks().count, 1)
        XCTAssertTrue(try MarkWork.commit(f.tab, host, "Rectangle"))
    }

    func test_aFailureOffTheMainActorPutsTheFileBackAndIsThrown() async throws {
        let f = try CommentFixture()
        let host = MarkHost()
        let marker = f.marker

        do {
            _ = try await MarkWork.shared.change(f.tab, host, "Adding", isCurrent: { true }) { _, _ -> Int in
                try marker.add(.rectangle, 0, [markPt(60, 80), markPt(260, 140)], markRed)
                throw InvalidOperationException("no")
            }
            XCTFail("The failure was swallowed.")
        } catch {
            XCTAssertTrue(error is InvalidOperationException)
        }

        XCTAssertTrue(f.marks().isEmpty)
        XCTAssertFalse(MarkWork.shared.running)
    }

    func test_aChangeForATabThatIsNoLongerInViewIsPutBack() async throws {
        let f = try CommentFixture()
        let host = MarkHost()
        let marker = f.marker

        let made = try await MarkWork.shared.change(f.tab, host, "Adding", isCurrent: { false }) { _, _ in
            try marker.add(.rectangle, 0, [markPt(60, 80), markPt(260, 140)], markRed).type
        }

        XCTAssertNil(made)
        XCTAssertTrue(f.marks().isEmpty)
    }

    func test_aStopPutsTheFileBackOnceTheJobHasReallyEnded() async throws {
        let f = try CommentFixture()
        let host = MarkHost()
        host.cancelOnStart = true
        let marker = f.marker

        let made = try await MarkWork.shared.change(f.tab, host, "Adding", isCurrent: { true }) { _, _ in
            try marker.add(.rectangle, 0, [markPt(60, 80), markPt(260, 140)], markRed).type
        }

        XCTAssertNil(made)
        XCTAssertFalse(MarkWork.shared.running)
        XCTAssertTrue(f.marks().isEmpty)
        XCTAssertEqual(host.statuses, ["Canceled."])
    }
}
