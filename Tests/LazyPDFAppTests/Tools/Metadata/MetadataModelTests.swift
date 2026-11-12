import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/stamps/MetadataPanelTests.cs: the properties form as the window drives it. What is
// typed survives other commits, and the file's own limits apply. The Windows tests set a TextBox; these set the property of
// the model that the view binds to.

@MainActor
final class MetadataModelTests: XCTestCase {
    private func attached(_ bytes: [UInt8]? = nil, password: String? = nil) throws -> (model: MetadataModel, rig: ToolRig) {
        let rig = try ToolRig(bytes, password: password)
        let model = MetadataModel()
        rig.attach(model)
        return (model, rig)
    }

    func test_typedPropertiesSurviveACommitFromElsewhere() async throws {
        let (model, rig) = try attached()
        model.title = "Report"

        var elsewhere = DocumentMetadata.read(rig.tab.document)
        elsewhere.creator = "Maker"
        try elsewhere.write(rig.tab.document)
        try rig.tab.commit("Properties")
        await waitUntil { model.makerText == "Maker" }

        XCTAssertEqual(model.title, "Report")
        XCTAssertTrue(model.action!.canRun())
    }

    func test_typedPropertiesComeBackWhenThePanelIsShownAgain() async throws {
        let (model, rig) = try attached()
        model.title = "Report"

        model.detach()
        model.attach(rig.tab, rig.viewer, RecordingHost())

        XCTAssertEqual(model.title, "Report")
    }

    func test_typedPropertiesAreLeftWhenThePanelIsShownForAnotherDocument() async throws {
        let (model, _) = try attached()
        model.title = "Report"

        model.detach()
        let other = try ToolRig()
        model.attach(other.tab, other.viewer, other.host)

        XCTAssertEqual(model.title, "")
    }

    func test_handingInPutsTypedPropertiesInTheFileAndMarksItUnsaved() async throws {
        let (model, rig) = try attached()
        model.title = "Report"
        XCTAssertFalse(rig.tab.isDirty)

        _ = model.handIn()

        XCTAssertEqual(DocumentMetadata.read(rig.tab.document).title, "Report")
        XCTAssertTrue(rig.tab.isDirty)
        XCTAssertFalse(model.action!.canRun())
    }

    func test_handingInOnASignedFileWaitsForTheAnswer() async throws {
        let (model, rig) = try attached(try Pdfs.signed(certified: false))
        model.title = "Report"

        XCTAssertFalse(model.handIn())
        XCTAssertEqual(rig.host.notices.count, 1)
        XCTAssertFalse(rig.tab.isDirty)

        rig.host.notices[0].action?.run()
        XCTAssertTrue(rig.tab.isDirty)
        XCTAssertTrue(model.handIn())
    }

    func test_savingAfterClearingTheTitleSaysTheOldOneStaysInTheFile() async throws {
        let (model, rig) = try attached()
        model.title = "Report"
        _ = model.handIn()
        XCTAssertTrue(rig.host.notices.isEmpty)

        model.title = ""
        await model.action!.run()
        XCTAssertEqual(rig.host.notices.count, 1)
        XCTAssertEqual(rig.host.notices[0].0, "Old values are still in the file")

        _ = model.handIn()
        XCTAssertEqual(rig.host.notices.count, 1)
    }

    func test_leavingOneFieldForAnotherWaitsForSaveToSayIt() async throws {
        let (model, rig) = try attached()
        model.title = "Report"
        _ = model.handIn()

        model.title = ""
        _ = model.store(notify: false)
        XCTAssertTrue(rig.host.notices.isEmpty)

        _ = model.handIn()
        XCTAssertEqual(rig.host.notices.count, 1)
    }

    func test_addingTextSaysNothingAboutOldValues() async throws {
        let (model, rig) = try attached()
        model.title = "Report"
        model.author = "Ann"
        _ = model.handIn()

        XCTAssertTrue(rig.host.notices.isEmpty)
    }

    func test_handingInWithNothingTypedChangesNothing() async throws {
        let (model, rig) = try attached()

        XCTAssertTrue(model.handIn())

        XCTAssertFalse(rig.tab.isDirty)
    }

    func test_savingWritesTheFormAndTheFormThenMatchesTheFile() async throws {
        let (model, rig) = try attached()
        model.title = "Report"

        await model.action!.run()

        XCTAssertEqual(DocumentMetadata.read(rig.tab.document).title, "Report")
        XCTAssertEqual(rig.host.statuses.last, "Properties changed.")
        XCTAssertEqual(model.title, "Report")
        XCTAssertFalse(model.action!.canRun())
    }

    func test_aFileThatForbidsChangesKeepsItsProperties() async throws {
        let (model, rig) = try attached(try Pdfs.restricted(PdfPermissions.all.subtracting(.modify)), password: "")
        model.title = "Report"

        await model.action!.run()

        XCTAssertEqual(rig.host.problems.count, 1)
        XCTAssertEqual(rig.host.problems.first?.title, "This file cannot be changed")
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_aCertifiedFileAsksBeforeItsPropertiesChange() async throws {
        let (model, rig) = try attached(try Pdfs.signed(certified: true))
        model.title = "Report"

        await model.action!.run()
        XCTAssertEqual(rig.host.notices.count, 1)
        XCTAssertFalse(rig.tab.session.canUndo)

        rig.host.notices[0].action?.run()
        XCTAssertTrue(rig.tab.session.canUndo)
    }

    func test_aCreatedDateOutsideTheSupportedRangeIsNotWritten() async throws {
        let (model, rig) = try attached()
        model.title = "Report"
        model.created = Date(timeIntervalSince1970: -62_135_596_800)

        await model.action!.run()

        let read = DocumentMetadata.read(rig.tab.document)
        XCTAssertEqual(read.title, "Report")
        XCTAssertNil(read.created)
    }

    func test_aCreatedDayIsWrittenAtMidnightOfTheDayChosen() async throws {
        let (model, rig) = try attached()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        model.created = calendar.date(from: DateComponents(year: 2024, month: 5, day: 17, hour: 15))

        await model.action!.run()

        let written = try XCTUnwrap(DocumentMetadata.read(rig.tab.document).created)
        XCTAssertEqual([written.year, written.month, written.day, written.hour], [2024, 5, 17, 0])
    }

    func test_theChoicesAndSwitchesAreWrittenAndReadBack() async throws {
        let (model, rig) = try attached()
        model.modeIndex = 2
        model.layoutIndex = 5
        model.language = "tr-TR"
        model.rightToLeft = true
        model.sidesIndex = 2
        model.copiesIndex = 2

        await model.action!.run()

        let view = ViewerSettings.read(rig.tab.document)
        XCTAssertEqual(view.pageMode, .useThumbs)
        XCTAssertEqual(view.pageLayout, .twoPageRight)
        XCTAssertEqual(view.language, "tr-TR")
        XCTAssertTrue(view.rightToLeft)
        XCTAssertEqual(view.duplex, "DuplexFlipLongEdge")
        XCTAssertEqual(view.numCopies, 3)
    }

    func test_theChangedDateIsLeftAloneWhenTheSwitchIsOff() async throws {
        let (model, rig) = try attached()
        let before = DocumentMetadata.read(rig.tab.document).modified
        model.title = "Report"
        model.touchModified = false

        await model.action!.run()

        XCTAssertEqual(DocumentMetadata.read(rig.tab.document).modified, before)
    }

    func test_theChangedDateMovesWhenTheSwitchIsOn() async throws {
        let (model, rig) = try attached()
        model.title = "Report"

        await model.action!.run()

        let modified = try XCTUnwrap(DocumentMetadata.read(rig.tab.document).modified)
        XCTAssertGreaterThanOrEqual(modified.year, 2026)
    }

    func test_theButtonAfterAHandInFindsNothingLeftToSave() async throws {
        let (model, rig) = try attached()
        model.title = "Report"
        XCTAssertTrue(model.handIn())
        let revision = rig.tab.revision

        await model.action!.run()

        XCTAssertEqual(rig.tab.revision, revision)
    }
}
