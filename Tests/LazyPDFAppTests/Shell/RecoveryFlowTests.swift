import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/RecoveryFlowTests.cs: after a crash, what was open is offered back, with its unsaved
// changes. The last test flushes the view model's store where the Windows test polls the folder.

@MainActor
final class RecoveryFlowTests: XCTestCase {
    // A document with a change in it, as the app left it in the recovery folder when it died.
    private func crash(_ f: ViewModelFixture, _ name: String, _ originalPath: String?) throws {
        let session = try PdfEditSession.open(Pdfs.text())
        try Pdfs.retitle(session, "Unsaved title")
        try session.commit("Properties")
        let store = RecoveryStore(directory: f.folders.recovery)
        store.write(UUID(), session.current, RecoveryMeta(title: name, originalPath: originalPath, saved: Date()))
        store.flush()
    }

    func test_withNothingLeftThereIsNothingToOffer() async {
        let f = ViewModelFixture(self)

        f.vm.checkRecovery()

        XCTAssertNil(f.vm.recoveryOffer)
    }

    func test_whatACrashLeftIsOffered() async throws {
        let f = ViewModelFixture(self)
        try crash(f, "report.pdf", f.dir.sub("report.pdf").path)

        f.vm.checkRecovery()

        XCTAssertEqual(f.vm.recoveryOffer?.count, 1)
        XCTAssertEqual(f.vm.recoveryOffer?.first?.meta.title, "report.pdf")
    }

    func test_restoringOpensItAsADocumentWithUnsavedChanges() async throws {
        let f = ViewModelFixture(self)
        let original = f.pdf("report.pdf")
        try crash(f, "report.pdf", original.path)
        f.vm.checkRecovery()

        await f.vm.restore()

        XCTAssertNil(f.vm.recoveryOffer)
        XCTAssertEqual(f.vm.documents.count, 1)
        let tab = f.vm.documents[0]
        XCTAssertTrue(tab.isDirty)
        XCTAssertTrue(samePath(tab.url, original))
        XCTAssertEqual(DocumentMetadata.read(tab.document).title, "Unsaved title")
    }

    func test_aRestoredDocumentSavesOverTheOriginal() async throws {
        let f = ViewModelFixture(self)
        let original = f.pdf("report.pdf")
        try crash(f, "report.pdf", original.path)
        f.vm.checkRecovery()
        await f.vm.restore()

        XCTAssertTrue(f.vm.save(f.vm.activeDocument!))

        XCTAssertEqual(DocumentMetadata.read(try PdfDocument.open(path: original.path)).title, "Unsaved title")
        XCTAssertFalse(f.vm.activeDocument!.isDirty)
    }

    func test_aRestoredDocumentIsNotOfferedAgainAfterItIsSaved() async throws {
        let f = ViewModelFixture(self)
        try crash(f, "report.pdf", f.pdf("report.pdf").path)
        f.vm.checkRecovery()
        await f.vm.restore()
        f.vm.save(f.vm.activeDocument!)

        f.vm.checkRecovery()

        XCTAssertNil(f.vm.recoveryOffer)
    }

    func test_aDocumentWithNoFileComesBackNeedingAName() async throws {
        let f = ViewModelFixture(self)
        try crash(f, "scan.pdf", nil)
        f.vm.checkRecovery()

        await f.vm.restore()

        XCTAssertTrue(AppViewModel.needsName(f.vm.activeDocument!))
        XCTAssertEqual(f.vm.activeDocument?.title, "scan.pdf")
    }

    func test_discardingRemovesWhatWasLeft() async throws {
        let f = ViewModelFixture(self)
        try crash(f, "a.pdf", nil)
        try crash(f, "b.pdf", nil)
        f.vm.checkRecovery()

        f.vm.discardRecovery()
        f.vm.checkRecovery()

        XCTAssertNil(f.vm.recoveryOffer)
        XCTAssertTrue(RecoveryStore(directory: f.folders.recovery).list().isEmpty)
    }

    func test_everyCommitIsWrittenAndAClosedDocumentLeavesNothing() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = f.vm.activeDocument!
        try Pdfs.retitle(tab.session, "x")
        try tab.commit("x")
        f.vm.recovery.flush()
        let store = RecoveryStore(directory: f.folders.recovery)

        XCTAssertEqual(store.list().count, 1)

        f.vm.close(tab)
        XCTAssertTrue(store.list().isEmpty)
    }
}
