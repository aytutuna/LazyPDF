import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Clean for sharing panel as the window drives it: the scan on attach and after a change, the ticks, the run and where its
// result goes. Windows has no test of the panel itself; the job and the output are tested with SanitizeJobTests and
// OutputWriterTests.

@MainActor
final class SanitizeModelTests: XCTestCase {
    private func titled() throws -> [UInt8] {
        let session = try PdfEditSession.open(Pdfs.text(2))
        try Pdfs.retitle(session, "Salary figures")
        try session.commit("Title")
        return session.current
    }

    private func attached(_ bytes: [UInt8]? = nil, password: String? = nil) async throws -> (model: SanitizeModel, rig: ToolRig) {
        let rig = try ToolRig(bytes ?? titled(), password: password)
        let model = SanitizeModel()
        rig.attach(model)
        await model.scan().value
        return (model, rig)
    }

    func test_whileTheFileIsSearchedThePanelSaysSoAndHasNothingToRun() async throws {
        let rig = try ToolRig(titled())
        let model = SanitizeModel()

        rig.attach(model)

        XCTAssertEqual(model.found, "Looking through the file.")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.action!.canRun())
    }

    func test_theScanListsWhatTheFileHoldsWithTheTicksOn() async throws {
        let (model, _) = try await attached()

        XCTAssertEqual(model.found, "Tick what to remove.")
        let metadata = try XCTUnwrap(model.rows.first { $0.item == .metadata })
        XCTAssertTrue(metadata.isChecked)
        XCTAssertFalse(model.rows.contains { [.comments, .formData, .externalLinks].contains($0.item) && $0.isChecked })
        XCTAssertTrue(model.action!.canRun())
    }

    func test_theButtonRunsOnlyWhileSomethingIsTicked() async throws {
        let (model, _) = try await attached()

        for row in model.rows { model.setChecked(row, false) }

        // What is always removed stays ticked, and keeps the button on.
        XCTAssertEqual(model.rows.filter(\.isChecked).allSatisfy { !$0.canTick }, true)
        XCTAssertEqual(model.action!.canRun(), model.rows.contains { $0.isChecked })
    }

    func test_aRowThatIsAlwaysRemovedCannotBeSwitched() async throws {
        let (model, _) = try await attached()
        let row = SanitizeRow(SanitizeFinding(.signatures, 1))
        XCTAssertFalse(row.canTick)

        model.setChecked(row, false)

        XCTAssertFalse(model.rows.contains { $0.item == .signatures && !$0.isChecked })
    }

    func test_aProtectedFileIsNotSearchedWithoutItsOwnerPassword() async throws {
        let (model, _) = try await attached(try Pdfs.restricted(PdfPermissions.all.subtracting(.modify)), password: "")

        XCTAssertEqual(model.found, "This file is protected. Open it with its owner password to use this tool.")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.action!.canRun())
    }

    func test_aRunOpensTheCleanFileInANewTabAndSaysWhatWentOut() async throws {
        let (model, rig) = try await attached()

        await model.action!.run()

        XCTAssertEqual(rig.host.openedNew.count, 1)
        XCTAssertEqual(rig.host.openedNew[0].title, "a (clean).pdf")
        XCTAssertEqual(rig.host.notices.last?.title, "File cleaned")
        XCTAssertTrue(rig.host.notices.last?.text.hasPrefix("Removed: ") == true)
        XCTAssertEqual(rig.host.statuses.last, "File cleaned.")
        let cleaned = try PdfDocument.open(rig.host.openedNew[0].pdf)
        XCTAssertNotEqual(DocumentMetadata.read(cleaned).title, "Salary figures")
        XCTAssertEqual(DocumentMetadata.read(rig.tab.document).title, "Salary figures")
    }

    func test_whatWasLeftUntickedIsSaidToHaveStayedIn() async throws {
        let (model, rig) = try await attached()
        for row in model.rows where row.item == .metadata { model.setChecked(row, false) }

        await model.action!.run()

        XCTAssertTrue(rig.host.notices.last?.text.contains("Left in: ") == true)
    }

    func test_aChangeToTheFileSearchesItAgain() async throws {
        let (model, rig) = try await attached(Pdfs.text())
        let before = model.rows.first { $0.item == .metadata }?.count ?? 0

        try Pdfs.retitle(rig.tab.session, "Salary figures")
        try rig.tab.commit("Properties")

        await waitUntil { (model.rows.first { $0.item == .metadata }?.count ?? 0) > before }
    }

    func test_aSignedFileIsNotReplacedAndSaysSignaturesGo() async throws {
        let (model, _) = try await attached(try Pdfs.signed(certified: false))

        XCTAssertTrue(model.output.isSigned)
        XCTAssertFalse(model.output.canReplace)
        XCTAssertEqual(model.output.signedNote, "Signatures are removed from the result.")
    }
}
