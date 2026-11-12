import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/CloseFlowTests.cs: closing and saving through the view model; unsaved changes are
// asked about, the strip keeps Home first. The failed save is made to fail by a name in a folder that is not there, since
// macOS does not lock a file the way the Windows test does.

@MainActor
final class CloseFlowTests: XCTestCase {
    private func openDirty(_ f: ViewModelFixture, _ name: String = "a.pdf") async throws -> DocumentTab {
        await f.vm.open(f.pdf(name))
        let tab = f.vm.activeDocument!
        try Pdfs.retitle(tab.session, "Changed")
        try tab.commit("Properties")
        return tab
    }

    func test_aCleanTabClosesAtOnce() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = f.vm.activeDocument!

        XCTAssertTrue(f.vm.requestClose(tab))

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertTrue(f.vm.isHome)
        XCTAssertTrue(f.renderers[0].disposed)
    }

    func test_aTabWithChangesIsAskedAboutAndStaysOpen() async throws {
        let f = ViewModelFixture(self)
        let tab = try await openDirty(f)

        XCTAssertFalse(f.vm.requestClose(tab))

        XCTAssertTrue(f.vm.closeQuestion === tab)
        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_aTabWithRedactionMarksWaitingIsAskedAboutAndStaysOpen() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = f.vm.activeDocument!
        tab.pendingMarks = 3

        XCTAssertFalse(f.vm.requestClose(tab))

        XCTAssertTrue(f.vm.closeQuestion === tab)
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_exitAsksAboutAnUnappliedRedactionMarkToo() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = f.vm.activeDocument!
        tab.pendingMarks = 1

        XCTAssertFalse(f.vm.requestExit())

        XCTAssertTrue(f.vm.closeQuestion === tab)
    }

    func test_cancellingTheQuestionKeepsTheDocument() async throws {
        let f = ViewModelFixture(self)
        let tab = try await openDirty(f)
        f.vm.requestClose(tab)

        f.vm.cancelClose()

        XCTAssertNil(f.vm.closeQuestion)
        XCTAssertEqual(f.vm.documents.count, 1)
        XCTAssertTrue(tab.isDirty)
    }

    func test_savingThenClosingWritesTheFileAndEndsTheTab() async throws {
        let f = ViewModelFixture(self)
        let tab = try await openDirty(f)
        f.vm.requestClose(tab)

        XCTAssertTrue(f.vm.save(tab))
        f.vm.close(tab)

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertEqual(DocumentMetadata.read(try PdfDocument.open(path: f.dir.sub("a.pdf").path)).title, "Changed")
        XCTAssertNil(f.vm.closeQuestion)
    }

    func test_saveAnywayFromTheCloseQuestionClosesTheTab() async throws {
        let f = ViewModelFixture(self)
        let tab = try await openDirty(f)
        try touch(f.dir.sub("a.pdf"), Pdfs.text(3))
        f.vm.checkDisk()
        f.vm.requestClose(tab)

        XCTAssertFalse(f.vm.save(tab, closeAfter: true))
        f.vm.message?.action?.run()

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertNil(f.vm.closeQuestion)
    }

    func test_saveAnywayKeepsTheTabWhileTheToolStillHoldsTyping() async throws {
        let f = ViewModelFixture(self)
        let tab = try await openDirty(f)
        try touch(f.dir.sub("a.pdf"), Pdfs.text(3))
        f.vm.checkDisk()
        f.vm.requestClose(tab)
        XCTAssertFalse(f.vm.save(tab, closeAfter: true))
        f.vm.handInTyping = { false }

        f.vm.message?.action?.run()

        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_saveAnywayOutsideTheCloseQuestionKeepsTheTab() async throws {
        let f = ViewModelFixture(self)
        let tab = try await openDirty(f)
        try touch(f.dir.sub("a.pdf"), Pdfs.text(3))
        f.vm.checkDisk()

        XCTAssertFalse(f.vm.save(tab))
        f.vm.message?.action?.run()

        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_discardingClosesWithoutWriting() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        let before = try Data(contentsOf: url)
        await f.vm.open(url)
        let tab = f.vm.activeDocument!
        try Pdfs.retitle(tab.session, "Changed")
        try tab.commit("Properties")
        f.vm.requestClose(tab)

        f.vm.close(tab)

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func test_closingTheActiveTabShowsItsNeighbour() async {
        let f = ViewModelFixture(self)
        await f.vm.open([f.pdf("a.pdf"), f.pdf("b.pdf"), f.pdf("c.pdf")])
        let tabs = f.vm.documents
        f.vm.select(tabs[1])

        f.vm.close(tabs[1])

        XCTAssertEqual(f.vm.activeDocument?.title, "c.pdf")
        f.vm.close(tabs[2])
        XCTAssertEqual(f.vm.activeDocument?.title, "a.pdf")
    }

    func test_aFailedSaveSaysSoAndKeepsTheChanges() async throws {
        let f = ViewModelFixture(self)
        let tab = try await openDirty(f)

        XCTAssertFalse(f.vm.saveAs(tab, f.dir.sub("no such folder/a.pdf")))

        XCTAssertEqual(f.vm.message?.title, "Not saved")
        XCTAssertTrue(tab.isDirty)
    }

    func test_saveAsGivesAMadeDocumentItsFile() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.dir.file("pic.png", [1, 2, 3]))
        let tab = f.vm.activeDocument!
        let target = f.dir.sub("pic.pdf")

        XCTAssertTrue(f.vm.saveAs(tab, target))

        XCTAssertEqual(tab.title, "pic.pdf")
        XCTAssertFalse(tab.isDirty)
        XCTAssertTrue(f.vm.recent.contains { samePath($0.url, target) })
        XCTAssertTrue(f.vm.statusFull.contains("pic.pdf"))
        XCTAssertNil(f.vm.message)
    }

    func test_saveCompactWritesTheDocumentAnewAndForgetsItsHistory() async throws {
        let f = ViewModelFixture(self)
        let tab = try await openDirty(f)

        XCTAssertTrue(f.vm.saveCompact(tab, f.dir.sub("small.pdf")))

        XCTAssertFalse(f.vm.canUndo)
        XCTAssertEqual(tab.title, "small.pdf")
        XCTAssertEqual(f.vm.message?.title, "Saved compact")
    }

    func test_tabsCanBeMovedButHomeStaysFirst() async {
        let f = ViewModelFixture(self)
        await f.vm.open([f.pdf("a.pdf"), f.pdf("b.pdf"), f.pdf("c.pdf")])
        let tabs = f.vm.documents

        f.vm.moveTab(tabs[2], to: 1)
        XCTAssertEqual(f.vm.documents.map(\.title), ["c.pdf", "a.pdf", "b.pdf"])

        f.vm.moveTab(tabs[0], to: 0)
        XCTAssertTrue(f.vm.strip[0] === HomeTab.shared)
        XCTAssertEqual(f.vm.documents.map(\.title), ["a.pdf", "c.pdf", "b.pdf"])

        f.vm.moveTab(tabs[1], to: 99)
        XCTAssertEqual(f.vm.documents.last?.title, "b.pdf")
    }

    func test_homeCannotBeClosedOrMoved() async {
        let f = ViewModelFixture(self)
        await f.vm.open([f.pdf("a.pdf"), f.pdf("b.pdf")])

        XCTAssertFalse(HomeTab.shared.canClose)
        XCTAssertTrue(f.vm.strip[0] === HomeTab.shared)
    }

    func test_undoAndRedoActOnTheActiveDocument() async throws {
        let f = ViewModelFixture(self)
        _ = try await openDirty(f)
        XCTAssertTrue(f.vm.canUndo)
        XCTAssertEqual(f.vm.undoLabel, "Properties")

        f.vm.undo()
        XCTAssertFalse(f.vm.canUndo)
        XCTAssertTrue(f.vm.canRedo)

        f.vm.redo()
        XCTAssertTrue(f.vm.canUndo)
    }

    func test_undoWithNoDocumentDoesNothing() async {
        let f = ViewModelFixture(self)

        f.vm.undo()
        f.vm.redo()

        XCTAssertFalse(f.vm.canUndo)
    }
}
