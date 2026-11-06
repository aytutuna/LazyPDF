import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/RecoveryWritesTests.cs: the recovery copy follows the document: written for every edit,
// gone when the document is clean, and not mistaken for a live one.

@MainActor
final class RecoveryWritesTests: XCTestCase {
    func test_aWriteJustAfterTheWorkerFinishedIsStillWritten() {
        let dir = TempDir(self)
        let store = RecoveryStore(directory: dir.url)
        let id = UUID()

        for i in 1...300 {
            store.write(id, [UInt8(i % 250), UInt8(i % 256)], RecoveryMeta(title: String(i)))
            store.flush()
            let entries = store.list()
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.meta.title, String(i))
        }
    }

    func test_undoingBackToTheSavedStateRemovesTheCopy() throws {
        let dir = TempDir(self)
        let store = RecoveryStore(directory: dir.sub("recovery"))
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text()), renderer: FakeRenderer(), url: nil, title: "a.pdf", recovery: store)
        try Pdfs.retitle(tab.session, "Changed")
        try tab.commit("Properties")
        store.flush()
        XCTAssertEqual(store.list().count, 1)

        try tab.undo()
        store.flush()

        XCTAssertFalse(tab.isDirty)
        XCTAssertTrue(store.list().isEmpty)
    }

    func test_entriesOfAProcessThatIsStillRunningAreNotCrashLeftovers() {
        let dir = TempDir(self)
        let store = RecoveryStore(directory: dir.url)
        store.write(UUID(), [1], RecoveryMeta(title: "live", processId: Int(ProcessInfo.processInfo.processIdentifier)))
        store.write(UUID(), [1], RecoveryMeta(title: "gone", processId: Int(Int32.max)))
        store.write(UUID(), [1], RecoveryMeta(title: "old"))
        store.flush()

        XCTAssertEqual(store.list().count, 3)
        XCTAssertEqual(store.abandoned().map(\.meta.title).sorted(), ["gone", "old"])
    }

    func test_aWindowBesideALiveOneDoesNotOfferItsDocuments() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        try Pdfs.retitle(f.vm.activeDocument!.session, "Unsaved")
        try f.vm.activeDocument!.commit("Properties")
        f.vm.recovery.flush()
        XCTAssertEqual(RecoveryStore(directory: f.folders.recovery).list().count, 1)
        let beside = f.makeViewModel()

        beside.checkRecovery()

        XCTAssertNil(beside.recoveryOffer)
    }
}
