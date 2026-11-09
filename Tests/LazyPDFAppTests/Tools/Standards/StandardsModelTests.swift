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
        model.setLevel(3)
        XCTAssertFalse(model.showsResult)
        XCTAssertEqual(model.levelNote, "Like 2b, and other files may be attached.")
        XCTAssertEqual(model.action!.text, "Check")
    }

    func test_theModesSayWhatTheyDoAndTheButtonNamesTheLevel() throws {
        let (model, _) = try attached()
        XCTAssertEqual(model.modeNote, "Lists the rules the file breaks. Nothing is changed.")

        model.setMode(.convert)

        XCTAssertEqual(model.modeNote, "Makes a new file and tries to meet the level. This file stays as it is.")
        XCTAssertEqual(model.action!.text, "Convert to PDF/A-2b")
        model.setLevel(5)
        XCTAssertEqual(model.action!.text, "Convert to PDF/A-4")
    }

    func test_whatConvertingCostsIsShownOnlyInConvertMode() throws {
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

    func test_aFileWithoutOwnerRightsIsRefusedInTheEngineWords() async throws {
        let (model, rig) = try attached(try Pdfs.restricted(.print), password: "")
        model.setMode(.convert)

        await model.action!.run()

        XCTAssertTrue(rig.host.openedNew.isEmpty)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Not converted"])
        XCTAssertFalse(rig.host.problems[0].text.isEmpty)
    }

    func test_aRuleThatNamesPagesTakesTheViewerThereInTurn() throws {
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
        XCTAssertEqual(rig.host.statuses.last, "Cancelled.")
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
