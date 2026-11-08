import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The gate in front of a change that is not a tool's pinned button (windows/LazyPDF.App/Tools/Stamps/ChangeGate.cs), and the
// choice of where a rewritten file goes (OutputChoice.xaml.cs). Windows tests both through the panels that use them.

@MainActor
final class ChangeGateTests: XCTestCase {
    func test_anOrdinaryFileIsChangedAtOnce() throws {
        let rig = try ToolRig()
        var ran = 0

        ChangeGate.run(rig.tab, rig.host, "Job") { ran += 1 }

        XCTAssertEqual(ran, 1)
        XCTAssertTrue(rig.host.problems.isEmpty)
        XCTAssertTrue(rig.host.notices.isEmpty)
    }

    func test_aFileThatForbidsChangesIsLeftAloneAndSaysWhy() throws {
        let rig = try ToolRig(try Pdfs.restricted(PdfPermissions.all.subtracting(.modify)), password: "")
        var ran = 0

        ChangeGate.run(rig.tab, rig.host, "Job") { ran += 1 }

        XCTAssertEqual(ran, 0)
        XCTAssertEqual(rig.host.problems.first?.title, "This file cannot be changed")
    }

    func test_aSignedFileAsksAndGoesOnOnlyWhenTold() throws {
        let rig = try ToolRig(try Pdfs.signed(certified: false))
        var ran = 0

        ChangeGate.run(rig.tab, rig.host, "Job") { ran += 1 }
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(rig.host.notices.first?.title, "Check before going on")
        XCTAssertEqual(rig.host.notices.first?.text, "This file is signed, so changing it breaks the signatures.")

        rig.host.notices[0].action?.run()
        XCTAssertEqual(ran, 1)
    }

    func test_aCertifiedFileSaysViewersWillReportItAltered() throws {
        let rig = try ToolRig(try Pdfs.signed(certified: true))

        ChangeGate.run(rig.tab, rig.host, "Job") {}

        XCTAssertEqual(rig.host.notices.first?.text, "This file is certified, so changing it makes viewers report it as altered.")
    }

    func test_aJobThatFailsIsExplainedAndTheAppGoesOn() throws {
        let rig = try ToolRig()

        ChangeGate.run(rig.tab, rig.host, "Stamp") { throw InvalidOperationException("no") }

        XCTAssertEqual(rig.host.problems.first?.title, "Something went wrong")
        XCTAssertEqual(rig.host.problems.first?.text, "Stamp could not be finished. If part of it was done, Undo takes it back.")
    }

    func test_aJobThatWaitsIsGatedTheSameWay() async throws {
        let rig = try ToolRig(try Pdfs.signed(certified: false))
        var ran = 0

        await ChangeGate.runAsync(rig.tab, rig.host, "Job") { ran += 1 }
        XCTAssertEqual(ran, 0)

        rig.host.notices[0].action?.run()
        await waitUntil { ran == 1 }
    }

    func test_aFileThatWasNeverSavedCannotBeReplaced() throws {
        let rig = try ToolRig()
        let choice = OutputChoice()

        choice.configure(rig.tab, removesSignatures: false)
        choice.replace = true
        choice.configure(rig.tab, removesSignatures: false)

        XCTAssertFalse(choice.canReplace)
        XCTAssertFalse(choice.replace)
        XCTAssertEqual(choice.note, "This file is not saved yet.")
    }

    func test_aSignedFileIsNotReplacedAndTheNoteSaysWhatHappensToTheSignatures() throws {
        let rig = try ToolRig(try Pdfs.signed(certified: false))
        let choice = OutputChoice()

        choice.configure(rig.tab, removesSignatures: false)

        XCTAssertFalse(choice.canReplace)
        XCTAssertEqual(choice.note, "A signed file is not replaced. The result opens in a new tab.")
        XCTAssertEqual(choice.signedNote, "Signatures stay in the result but are no longer valid.")
        choice.configure(rig.tab, removesSignatures: true)
        XCTAssertEqual(choice.signedNote, "Signatures are removed from the result.")
    }

    func test_aSavedFileCanBeReplacedAndTheNoteFollowsTheChoice() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf("report.pdf"))
        let tab = try XCTUnwrap(f.vm.activeDocument)
        let choice = OutputChoice()

        choice.configure(tab, removesSignatures: true)
        XCTAssertTrue(choice.canReplace)
        XCTAssertEqual(choice.note, "Opens in a new tab. You name it when you save.")

        choice.replace = true
        XCTAssertEqual(choice.note, "Replaces the file on disk and clears Undo.")
    }
}
