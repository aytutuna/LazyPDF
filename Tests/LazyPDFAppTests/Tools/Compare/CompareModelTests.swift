import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Compare panel as the window drives it: the choice of what to compare with, the run, the filters, the jump to a row, the
// unlock question, and the comparison that stays with the tab. Windows has no test of the panel itself; the flow and the
// session have theirs (CompareFlowTests, CompareSessionTests).

@MainActor
final class CompareModelTests: XCTestCase {
    private func attached(_ bytes: [UInt8]? = nil, renderers: @escaping () -> DocumentRenderer = { FakeRenderer() })
        throws -> (model: CompareModel, rig: ToolRig, dir: TempDir) {
        let rig = try ToolRig(bytes ?? CompareKit.before())
        let model = CompareModel(renderers: renderers, fonts: FakeFonts())
        rig.attach(model)
        return (model, rig, TempDir(self))
    }

    private func compared(_ model: CompareModel, _ dir: TempDir, _ bytes: [UInt8]? = nil) async throws {
        model.choose(ToolFile(url: dir.file("other.pdf", try bytes ?? CompareKit.after())))
        await model.action!.run()
    }

    func test_nothingCanRunUntilAFileIsChosen() throws {
        let (model, _, dir) = try attached()

        XCTAssertEqual(model.chosenText, "No file chosen")
        XCTAssertFalse(model.action!.canRun())

        model.choose(ToolFile(url: dir.file("other.pdf", CompareKit.before())))

        XCTAssertEqual(model.chosenText, "other.pdf")
        XCTAssertTrue(model.action!.canRun())
    }

    func test_aFileWithNoHistoryOffersNoVersionToCompareWith() throws {
        let (model, _, _) = try attached()
        model.source = .version

        XCTAssertTrue(model.versions.isEmpty)
        XCTAssertFalse(model.action!.canRun())
    }

    func test_anEditedFileOffersItsOpenedStateAndComparesWithIt() async throws {
        let (model, rig, _) = try attached()
        try Pdfs.retitle(rig.tab.session, "Edited")
        try rig.tab.commit("Properties")
        await waitUntil { model.versions.count == 1 }
        model.source = .version

        XCTAssertEqual(model.versionNames, ["Version 1"])
        XCTAssertTrue(model.action!.canRun())
        await model.action!.run()

        XCTAssertEqual(model.shown?.session.old.title, "a.pdf, version 1")
        XCTAssertEqual(model.rows.count, 1)
    }

    func test_aRunListsTheDifferencesAndSaysHowManyThereAre() async throws {
        let (model, rig, dir) = try attached()

        try await compared(model, dir)

        XCTAssertNotNil(model.shown)
        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertEqual(model.summaryText, "\(model.rows.count) differences")
        XCTAssertNotNil(model.noteText)
        XCTAssertEqual(rig.host.statuses.last, model.summaryText)
        XCTAssertTrue(model.shown?.openIsNew == true)
    }

    func test_theFiltersNarrowTheListAndTheHeadline() async throws {
        let (model, _, dir) = try attached()
        try await compared(model, dir)
        let all = model.rows.count

        model.setPart(.text, false)
        model.setPart(.details, false)

        XCTAssertEqual(model.rows.count, 1)
        XCTAssertLessThan(model.rows.count, all)
        model.setPart(.forms, false)
        XCTAssertEqual(model.summaryText, "Nothing to show with these filters.")
    }

    func test_whenTheOpenFileIsTheOlderOneItsPagesAreTheOldSide() async throws {
        let (model, _, dir) = try attached()
        model.fileIsOlder = true

        try await compared(model, dir)

        XCTAssertEqual(model.shown?.openIsNew, false)
        XCTAssertEqual(model.shown?.session.old.title, "a.pdf")
    }

    func test_aRowTakesTheStageToItsPage() async throws {
        let (model, rig, dir) = try attached()
        try await compared(model, dir)
        let row = try XCTUnwrap(model.rows.first { $0.title == "other" })

        model.go(row)

        XCTAssertEqual(rig.viewer.revealed.count, 1)
        XCTAssertEqual(rig.viewer.revealed[0].page, row.newPage)
    }

    func test_aRowWithNoPlaceOnThePageOnlyGoesWhereTheFileHasOne() async throws {
        let (model, rig, dir) = try attached()
        try await compared(model, dir)
        let row = ChangeRow(kind: .removed, title: "Gone", subtitle: "", oldPage: 1, newPage: -1, oldBoxes: [], newBoxes: [])

        model.go(row)

        XCTAssertEqual(rig.viewer.sent, [])
        XCTAssertEqual(rig.host.statuses.last, "Only in the other file.")
        model.go(ChangeRow(kind: .added, title: "More", subtitle: "", oldPage: -1, newPage: 1, oldBoxes: [], newBoxes: []))
        XCTAssertEqual(rig.viewer.sent, [1])
    }

    func test_aChangeToTheOpenFileStopsTheJumpAndSaysSo() async throws {
        let (model, rig, dir) = try attached()
        try await compared(model, dir)
        let row = try XCTUnwrap(model.rows.first { $0.title == "other" })
        try Pdfs.retitle(rig.tab.session, "Later")
        try rig.tab.commit("Properties")

        model.go(row)

        XCTAssertTrue(rig.viewer.revealed.isEmpty)
        XCTAssertEqual(rig.host.statuses.last, "File changed. Compare again.")
    }

    func test_aLockedOtherFileAsksForItsPasswordAndRunsAgainWithIt() async throws {
        let (model, rig, dir) = try attached()
        model.choose(ToolFile(url: dir.file("locked.pdf", try CompareKit.locked("pw"))))

        await model.action!.run()

        XCTAssertNil(model.shown)
        XCTAssertEqual(model.unlockText, "locked.pdf is locked. Type its password.")
        XCTAssertFalse(model.unlockNeedsCertificate)
        XCTAssertEqual(rig.host.statuses.last, "File is locked.")

        model.password = "nope"
        await model.action!.run()
        XCTAssertEqual(model.unlockText, "locked.pdf did not open. Check it and compare again.")

        model.password = "pw"
        await model.action!.run()
        XCTAssertNotNil(model.shown)
        XCTAssertNil(model.unlockText)
        XCTAssertEqual(model.password, "")
    }

    func test_aFileForRecipientsAsksForACertificateAndSaysWhenThereIsNone() async throws {
        let (model, rig, dir) = try attached()
        model.choose(ToolFile(url: dir.file("recipients.pdf", Pdfs.forRecipients())))

        await model.action!.run()

        XCTAssertTrue(model.unlockNeedsCertificate)
        XCTAssertEqual(model.unlockText, "No certificate with a private key was found on this computer.")
        XCTAssertNil(model.shown)
        XCTAssertTrue(rig.host.problems.isEmpty)
    }

    func test_aComparisonStaysWithItsTabWhenThePanelLeavesAndComesBack() async throws {
        let (model, rig, dir) = try attached()
        try await compared(model, dir)
        let held = model.shown

        model.detach()
        XCTAssertNil(model.shown)
        XCTAssertTrue(model.rows.isEmpty)
        rig.attach(model)

        XCTAssertTrue(model.shown === held)
        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertEqual(model.chosenText, "other.pdf")
    }

    func test_anotherTabDoesNotSeeTheComparison() async throws {
        let (model, _, dir) = try attached()
        try await compared(model, dir)
        let second = try ToolRig(CompareKit.before())

        model.detach()
        second.attach(model)

        XCTAssertNil(model.shown)
        XCTAssertEqual(model.chosenText, "No file chosen")
    }

    func test_runningAgainReplacesTheHeldComparison() async throws {
        let (model, _, dir) = try attached()
        try await compared(model, dir)
        let first = model.shown

        await model.action!.run()

        XCTAssertNotNil(model.shown)
        XCTAssertFalse(model.shown === first)
    }

    func test_theSheetOpensOnTheComparisonAndClosesWithIt() async throws {
        let (model, _, dir) = try attached()
        try await compared(model, dir)

        model.openSheet()
        let window = try XCTUnwrap(model.shown?.window)

        XCTAssertTrue(model.sheetShown)
        XCTAssertEqual(window.rows.count, model.rows.count)
        model.setPart(.text, false)
        XCTAssertEqual(window.rows.count, model.rows.count)
        model.closeSheet()
        XCTAssertFalse(model.sheetShown)
        XCTAssertNil(model.shown?.window)
        XCTAssertTrue(window.isClosed)
    }

    func test_leavingThePanelClosesTheSheet() async throws {
        let (model, _, dir) = try attached()
        try await compared(model, dir)
        model.openSheet()
        let window = try XCTUnwrap(model.shown?.window)

        model.detach()

        XCTAssertTrue(window.isClosed)
        XCTAssertFalse(model.sheetShown)
    }

    func test_theReportOpensAsANewTab() async throws {
        let (model, rig, dir) = try attached()
        try await compared(model, dir)

        await model.writeReport()

        XCTAssertEqual(rig.host.openedNew.count, 1)
        XCTAssertEqual(rig.host.openedNew[0].title, "Comparison - a.pdf")
        XCTAssertFalse(model.isWritingReport)
    }

    func test_thePixelModeComparesHowThePagesLook() async throws {
        let (model, _, dir) = try attached(renderers: CompareKit.painted())
        model.byPixels = true

        try await compared(model, dir, CompareKit.before())

        XCTAssertEqual(model.shown?.session.byPixels, true)
        XCTAssertEqual(model.howText, "Compares how the pages look. Use it for scans and drawings.")
    }
}
