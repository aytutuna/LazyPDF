import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The PDF/A panel as the window drives it. Windows has no test of the panel itself; its pieces are tested with ConvertJobTests
// and PdfARowsTests. These cover the modes, the level, what a check leaves on the panel and when it is taken away.

@MainActor
final class StandardsModelTests: XCTestCase {
    private func attached(_ bytes: [UInt8]? = nil, password: String? = nil) throws -> (model: StandardsModel, rig: SecurityRig) {
        let rig = try SecurityRig(bytes, password: password)
        let model = StandardsModel(fonts: FakeFonts())
        rig.attach(model)
        return (model, rig)
    }

    func test_aCheckListsTheRulesTheFileBreaksAndSaysSo() async throws {
        let (model, rig) = try attached()
        XCTAssertFalse(model.showsResult)

        await model.action!.run()

        XCTAssertTrue(model.showsResult)
        XCTAssertTrue(model.verdict.hasPrefix("Does not pass the checks for PDF/A-2b. Rules broken: "))
        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertEqual(rig.host.statuses.last, "Fails PDF/A-2b checks.")
        XCTAssertEqual(rig.host.busyTexts, ["Checking PDF/A-2b"])
        XCTAssertFalse(model.working)
        XCTAssertTrue(model.action!.canRun())
    }

    func test_aVerdictGoesWhenTheFileOrTheLevelChanges() async throws {
        let (model, rig) = try attached()
        await model.action!.run()
        XCTAssertTrue(model.showsResult)

        try Pdfs.retitle(rig.tab.session, "Changed")
        try rig.tab.commit("Title")
        await waitUntil { !model.showsResult }

        await model.action!.run()
        XCTAssertTrue(model.showsResult)
        model.setLevel(StandardsModel.levels.firstIndex(of: .a3b)!)
        XCTAssertFalse(model.showsResult)
        XCTAssertEqual(model.levelNote, "Like 2b, and other files may be attached.")
        XCTAssertEqual(model.action!.text, "Check")
    }

    func test_theModesSayWhatTheyDoAndTheButtonNamesTheLevel() async throws {
        let (model, _) = try attached()
        XCTAssertEqual(model.modeNote, "Lists the rules the file breaks. Nothing is changed.")

        model.setMode(.convert)

        XCTAssertEqual(model.modeNote, "Makes a new file and tries to meet the level. This file stays as it is.")
        XCTAssertEqual(model.action!.text, "Convert to PDF/A-2b")
        model.setLevel(StandardsModel.levels.firstIndex(of: .a4)!)
        XCTAssertEqual(model.action!.text, "Convert to PDF/A-4")
    }

    func test_whatConvertingCostsIsShownOnlyInConvertMode() async throws {
        let (model, _) = try attached(try Pdfs.signed(certified: false))
        XCTAssertEqual(model.losses, "")

        model.setMode(.convert)

        XCTAssertEqual(model.losses, "The file is signed. The new file loses the signatures.")
    }

    func test_aConversionOpensInANewTabNamedAfterTheFileAndTheLevel() async throws {
        let (model, rig) = try attached()
        model.setMode(.convert)

        await model.action!.run()

        let made = try XCTUnwrap(rig.host.openedNew.first)
        XCTAssertTrue(made.title == "a (PDF-A-2b).pdf" || made.title == "a (converted).pdf", made.title)
        XCTAssertNil(made.password)
        XCTAssertEqual(rig.host.notices.count, 1)
        XCTAssertFalse(rig.tab.isDirty)
    }

    func test_theConvertedCopyIsCheckedWhenTheShellAttachesItLater() async throws {
        let (model, rig) = try attached()
        model.setMode(.convert)
        await model.action!.run()
        let made = try XCTUnwrap(rig.host.openedNew.first)
        XCTAssertFalse(model.showsResult)

        let copy = try SecurityRig(made.pdf, title: made.title)
        model.detach()
        copy.attach(model)

        await waitUntil { model.showsResult }
        XCTAssertTrue(model.showsResult)
        XCTAssertNotNil(copy.host.statuses.last)
    }

    func test_aFileWithoutOwnerRightsIsRefusedInTheEngineWords() async throws {
        let (model, rig) = try attached(try Pdfs.restricted(.print), password: "")
        model.setMode(.convert)

        await model.action!.run()

        XCTAssertTrue(rig.host.openedNew.isEmpty)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Not converted"])
        XCTAssertFalse(rig.host.problems[0].text.isEmpty)
    }

    private func taggedText(language: String?) throws -> [UInt8] {
        let document = try PdfDocument.open(Pdfs.text())
        _ = try AutoTagger.tag(document, AutoTagOptions(language))
        return try document.saveRewrite(PdfSaveOptions())
    }

    func test_anUntaggedFileAtALevelAIsToldToBeTaggedFirstAndTheButtonOpensAccessibility() async throws {
        let (model, rig) = try attached()
        XCTAssertFalse(model.needsTagging)
        XCTAssertEqual(model.tagHint, "")

        model.setLevel(StandardsModel.levels.firstIndex(of: .a2a)!)
        await waitUntil { model.needsTagging }

        XCTAssertEqual(model.tagHint, "PDF/A-2a needs a tagged file, and this one is not tagged well enough yet. Tag the file first, then run this again.")
        XCTAssertEqual(model.tagButton, "Tag the file")
        model.tagFile()
        XCTAssertTrue(rig.host.taggingRequested)

        model.setLevel(StandardsModel.levels.firstIndex(of: .a2b)!)
        XCTAssertFalse(model.needsTagging)
        XCTAssertEqual(model.tagHint, "")
    }

    func test_levelsPickedInQuickSuccessionEndOnTheAnswerForTheLastOne() async throws {
        let (model, _) = try attached()
        model.setLevel(StandardsModel.levels.firstIndex(of: .a1a)!)
        model.setLevel(StandardsModel.levels.firstIndex(of: .a2a)!)
        model.setLevel(StandardsModel.levels.firstIndex(of: .a3a)!)
        await waitUntil { model.needsTagging }
        XCTAssertTrue(model.needsTagging)

        model.setLevel(StandardsModel.levels.firstIndex(of: .a3a)!)
        model.setLevel(StandardsModel.levels.firstIndex(of: .a2b)!)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(model.needsTagging)
    }

    func test_theHintGoesWhenTheFileIsTaggedWellEnoughAndStaysWhenItIsNot() async throws {
        let (model, _) = try attached(try taggedText(language: "en-US"))
        model.setLevel(StandardsModel.levels.firstIndex(of: .a1a)!)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(model.needsTagging)

        // Tagged, but with no language to name, so the level's own check rejects the tagging.
        let weak = try SecurityRig(try taggedText(language: nil))
        model.detach()
        weak.attach(model)
        await waitUntil { model.needsTagging }
        XCTAssertTrue(model.needsTagging)
    }

    func test_aRuleThatNamesPagesTakesTheViewerThereInTurn() async throws {
        let (model, rig) = try attached()
        let row = try XCTUnwrap(IssueRow.group([
            PdfAIssue("6.5.3", PdfAText.pageName(2), "An annotation has no appearance."),
            PdfAIssue("6.5.3", PdfAText.pageName(1), "An annotation has no appearance."),
        ]).first)

        model.visit(row)
        model.visit(row)
        model.visit(row)

        XCTAssertEqual(rig.viewer.sent, [0, 1, 0])
        XCTAssertEqual(row.placeText, "Go to page 2")
    }

    func test_aCancelledCheckHoldsTheButtonUntilTheCheckHasEnded() async throws {
        let (model, rig) = try attached()
        rig.host.token.cancel()

        await model.action!.run()

        XCTAssertFalse(model.showsResult)
        XCTAssertEqual(rig.host.statuses.last, "Canceled.")
        await waitUntil { !model.working }
    }

    func test_leavingThePanelTakesTheResultAway() async throws {
        let (model, rig) = try attached()
        await model.action!.run()

        model.detach()
        XCTAssertFalse(model.showsResult)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.action!.canRun())
        model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertFalse(model.showsResult)
        XCTAssertTrue(model.action!.canRun())
    }
}
