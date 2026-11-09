import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Make smaller panel as the window drives it: the audit on attach and after a change, the settings, the run and where its
// result goes. Windows has no test of the panel itself; the job is tested with OptimizeJobTests.

@MainActor
final class OptimizeModelTests: XCTestCase {
    private func attached(_ bytes: [UInt8]? = nil, password: String? = nil) async throws -> (model: OptimizeModel, rig: ToolRig) {
        let rig = try ToolRig(bytes ?? Pdfs.text(3), password: password)
        let model = OptimizeModel(codec: FakeCodec())
        rig.attach(model)
        await model.showAudit().value
        return (model, rig)
    }

    func test_whileTheFileIsSearchedThePanelSaysSo() throws {
        let rig = try ToolRig(Pdfs.text(3))
        let model = OptimizeModel()

        rig.attach(model)

        XCTAssertEqual(model.total, "Looking through the file.")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.action!.canRun())
    }

    func test_theAuditShowsTheFileSizeAndTheRows() async throws {
        let (model, rig) = try await attached()

        XCTAssertEqual(model.total, "File size " + SizeText.of(rig.tab.session.current.count))
        XCTAssertFalse(model.rows.isEmpty)
    }

    func test_aProtectedFileIsNotSearchedAndHasNothingToRun() async throws {
        let (model, _) = try await attached(try Pdfs.restricted(PdfPermissions.all.subtracting(.modify)), password: "")

        XCTAssertEqual(model.total, "This file is protected. Open it with its owner password to use this tool.")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.action!.canRun())
    }

    func test_theSettingsMakeTheChoice() async throws {
        let (model, _) = try await attached()
        XCTAssertEqual(model.choice, OptimizeChoice(.balanced, .standard, grayscale: false, fastWebView: false))

        model.preset = .custom
        model.dpiIndex = 4
        model.quality = 60
        model.dropPrivateKeys = true
        model.grayscale = true

        XCTAssertEqual(model.choice.custom.imageDpi, 200)
        XCTAssertEqual(model.choice.custom.jpegQuality, 60)
        XCTAssertTrue(model.choice.custom.dropPrivateKeys)
        XCTAssertTrue(model.choice.grayscale)
    }

    func test_eachPresetHasANoteAndCustomHasNone() async throws {
        let (model, _) = try await attached()

        model.preset = .small
        XCTAssertEqual(model.presetNote, "Smallest file. Pictures drop to 96 dpi and lose some detail.")
        model.preset = .high
        XCTAssertEqual(model.presetNote, "Keeps detail for printing. Pictures stay up to 300 dpi.")
        model.preset = .custom
        XCTAssertEqual(model.presetNote, "")
    }

    func test_aRunOpensTheRewrittenFileInANewTab() async throws {
        let (model, rig) = try await attached()
        model.fastWebView = true

        await model.action!.run()

        XCTAssertEqual(rig.host.openedNew.count, 1)
        XCTAssertEqual(rig.host.openedNew[0].title, "a (smaller).pdf")
        XCTAssertTrue(["File made smaller", "File rewritten"].contains(rig.host.notices.last?.title))
        XCTAssertTrue(try PdfDocument.open(rig.host.openedNew[0].pdf).isLinearized)
    }

    func test_aChangeToTheFileSearchesItAgain() async throws {
        let (model, rig) = try await attached(Pdfs.text())
        let before = model.total

        try Pdfs.retitle(rig.tab.session, String(repeating: "Salary figures ", count: 40))
        try rig.tab.commit("Properties")

        await waitUntil { model.total != before && model.total.hasPrefix("File size") }
    }

    func test_aSignedFileIsNotReplacedAndSaysSignaturesStay() async throws {
        let (model, _) = try await attached(try Pdfs.signed(certified: false))

        XCTAssertTrue(model.output.isSigned)
        XCTAssertFalse(model.output.canReplace)
        XCTAssertEqual(model.output.signedNote, "Signatures stay in the result but are no longer valid.")
    }
}
