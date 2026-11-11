import XCTest
import Observation
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/DocumentTabTests.cs: one open document, the session, its renderer, the dirty state,
// saving, the recovery copy and the file on disk. The PropertyChanged test becomes an observation test.

@MainActor
final class DocumentTabTests: XCTestCase {
    private func open(path: URL? = nil, unsaved: Bool = false, recovery: RecoveryStore? = nil, pages: Int = 1) throws -> (DocumentTab, FakeRenderer) {
        let renderer = FakeRenderer()
        let session = try PdfEditSession.open(Pdfs.text(pages))
        return (DocumentTab(session: session, renderer: renderer, url: path, title: "Untitled.pdf", recovery: recovery, unsaved: unsaved), renderer)
    }

    private func written(_ dir: TempDir, _ name: String = "a.pdf") -> URL {
        dir.file(name, Pdfs.text())
    }

    private func title(of url: URL) throws -> String? {
        DocumentMetadata.read(try PdfDocument.open(path: url.path)).title
    }

    func test_aNewTabIsCleanAndDrawsItsFirstLoad() throws {
        let (tab, renderer) = try open()

        XCTAssertFalse(tab.isDirty)
        XCTAssertTrue(tab.canDraw)
        XCTAssertEqual(renderer.loads, 1)
        XCTAssertEqual(tab.revision, 0)
        XCTAssertEqual(tab.pageCount, 1)
    }

    func test_aCommitMakesItDirtyAndLoadsTheRendererAgain() throws {
        let (tab, renderer) = try open()
        var raised = 0
        tab.changed = { raised += 1 }
        try Pdfs.retitle(tab.session, "New title")

        XCTAssertTrue(try tab.commit("Properties"))

        XCTAssertTrue(tab.isDirty)
        XCTAssertEqual(renderer.loads, 2)
        XCTAssertEqual(tab.revision, 1)
        XCTAssertEqual(raised, 1)
    }

    func test_aCommitWithNothingChangedDoesNothing() throws {
        let (tab, renderer) = try open()

        XCTAssertFalse(try tab.commit("Nothing"))

        XCTAssertEqual(renderer.loads, 1)
        XCTAssertFalse(tab.isDirty)
    }

    func test_undoAndRedoMoveThroughTheSession() throws {
        let (tab, renderer) = try open()
        try Pdfs.retitle(tab.session, "One")
        try tab.commit("One")

        XCTAssertTrue(try tab.undo())
        XCTAssertFalse(tab.isDirty)
        XCTAssertTrue(try tab.redo())
        XCTAssertTrue(tab.isDirty)
        XCTAssertEqual(renderer.loads, 4)
        XCTAssertFalse(try tab.redo())
        XCTAssertEqual(tab.revision, 3)
    }

    func test_anUnsavedTabIsDirtyEvenWithNoHistory() throws {
        let (tab, _) = try open(unsaved: true)

        XCTAssertTrue(tab.isDirty)
    }

    func test_aTabWithNoFileTakesItsTitleFromTheGivenName() throws {
        let (tab, _) = try open()

        XCTAssertNil(tab.url)
        XCTAssertEqual(tab.title, "Untitled.pdf")
    }

    func test_saveWritesToTheFileItCameFromAndIsCleanAfterwards() throws {
        let dir = TempDir(self)
        let url = written(dir)
        let (tab, _) = try open(path: url)
        try Pdfs.retitle(tab.session, "Saved title")
        try tab.commit("Properties")

        try tab.save()

        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(try title(of: url), "Saved title")
        XCTAssertEqual(tab.title, "a.pdf")
    }

    func test_saveWithNoFileIsAMistake() throws {
        let (tab, _) = try open()

        XCTAssertThrowsError(try tab.save()) { XCTAssertTrue($0 is InvalidOperationException) }
    }

    func test_saveAsEndsTheReadOnlyState() throws {
        let dir = TempDir(self)
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text()), renderer: FakeRenderer(), url: written(dir),
                              title: "a.pdf", readOnly: true)
        XCTAssertTrue(tab.readOnly)

        try tab.saveAs(dir.sub("b.pdf"))

        XCTAssertFalse(tab.readOnly)
    }

    func test_saveAsGivesTheTabItsFileAndName() throws {
        let dir = TempDir(self)
        let (tab, _) = try open(unsaved: true)
        let url = dir.sub("made.pdf")
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)

        try tab.saveAs(url)

        XCTAssertEqual(tab.url, url)
        XCTAssertEqual(tab.title, "made.pdf")
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(try PdfDocument.open(path: url.path).pages.count, 1)
    }

    func test_saveCompactDropsTheHistory() throws {
        let dir = TempDir(self)
        let url = written(dir)
        let (tab, _) = try open(path: url)
        try Pdfs.retitle(tab.session, "Compact")
        try tab.commit("Properties")
        XCTAssertTrue(tab.session.canUndo)

        try tab.saveCompact(url)

        XCTAssertFalse(tab.session.canUndo)
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(try title(of: url), "Compact")
    }

    func test_saveGoesThroughTheSafeWriterAndLeavesNoTemporaryFile() throws {
        let dir = TempDir(self)
        let url = written(dir)
        let (tab, _) = try open(path: url)
        try Pdfs.retitle(tab.session, "x")
        try tab.commit("x")

        try tab.save()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        XCTAssertEqual(files, ["a.pdf"])
    }

    func test_aCommitIsWrittenToTheRecoveryFolder() throws {
        let dir = TempDir(self)
        let recovery = RecoveryStore(directory: dir.sub("recovery"))
        let (tab, _) = try open(recovery: recovery)
        try Pdfs.retitle(tab.session, "Recover me")
        try tab.commit("Properties")

        recovery.flush()

        let entries = recovery.list()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, tab.id)
        XCTAssertEqual([UInt8](try Data(contentsOf: entries[0].pdf)), tab.session.current)
    }

    func test_anUnsavedTabIsInTheRecoveryFolderFromTheStart() throws {
        let dir = TempDir(self)
        let recovery = RecoveryStore(directory: dir.sub("recovery"))
        _ = try open(unsaved: true, recovery: recovery)

        recovery.flush()

        XCTAssertEqual(recovery.list().count, 1)
    }

    func test_savingRemovesTheRecoveryCopy() throws {
        let dir = TempDir(self)
        let url = written(dir)
        let recovery = RecoveryStore(directory: dir.sub("recovery"))
        let (tab, _) = try open(path: url, recovery: recovery)
        try Pdfs.retitle(tab.session, "x")
        try tab.commit("x")

        try tab.save()
        recovery.flush()

        XCTAssertTrue(recovery.list().isEmpty)
    }

    func test_closingOnPurposeRemovesTheRecoveryCopyAndLetsGoOfTheRenderer() throws {
        let dir = TempDir(self)
        let recovery = RecoveryStore(directory: dir.sub("recovery"))
        let (tab, renderer) = try open(recovery: recovery)
        try Pdfs.retitle(tab.session, "x")
        try tab.commit("x")

        tab.dispose()

        XCTAssertTrue(renderer.disposed)
        XCTAssertTrue(recovery.list().isEmpty)
    }

    func test_aFileChangedByAnotherProgramIsNoticed() throws {
        let dir = TempDir(self)
        let url = written(dir)
        let (tab, _) = try open(path: url)
        XCTAssertFalse(tab.changedOnDisk)

        try touch(url, Pdfs.text(2), minutes: 5)

        XCTAssertTrue(tab.changedOnDisk)
        tab.acceptDiskState()
        XCTAssertFalse(tab.changedOnDisk)
    }

    func test_aFileThatWasDeletedCountsAsChanged() throws {
        let dir = TempDir(self)
        let url = written(dir)
        let (tab, _) = try open(path: url)

        try FileManager.default.removeItem(at: url)

        XCTAssertTrue(tab.changedOnDisk)
    }

    func test_ourOwnSaveIsNotAChangeByAnotherProgram() throws {
        let dir = TempDir(self)
        let url = written(dir)
        let (tab, _) = try open(path: url)
        try Pdfs.retitle(tab.session, "x")
        try tab.commit("x")

        try tab.save()

        XCTAssertFalse(tab.changedOnDisk)
    }

    func test_aTabWithNoFileNeverChangesOnDisk() throws {
        let (tab, _) = try open()

        XCTAssertFalse(tab.changedOnDisk)
    }

    func test_aDocumentTheSystemCannotDrawStillOpens() throws {
        let renderer = FakeRenderer()
        renderer.draws = false

        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text()), renderer: renderer, url: nil, title: "x.pdf")

        XCTAssertFalse(tab.canDraw)
        XCTAssertEqual(tab.pageCount, 1)
    }

    func test_thePageAndZoomAreKeptForTheViewer() throws {
        let (tab, _) = try open(pages: 3)

        tab.pageIndex = 2
        tab.zoom = 1.5

        XCTAssertEqual(tab.pageIndex, 2)
        XCTAssertEqual(tab.zoom, 1.5)
    }

    func test_theDerivedStateIsAnnouncedWhenItChanges() throws {
        let (tab, _) = try open()
        let announced = Counter()
        withObservationTracking({ _ = tab.isDirty }, onChange: { announced.count += 1 })
        try Pdfs.retitle(tab.session, "x")

        try tab.commit("x")

        XCTAssertEqual(announced.count, 1)
    }

    func test_theAutomationNameSaysThereAreUnsavedChanges() throws {
        let (tab, _) = try open(unsaved: true)

        XCTAssertEqual(tab.automationName, "Untitled.pdf, unsaved changes")
    }
}
