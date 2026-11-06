import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/DocumentLossTests.cs: unsaved work is never given up before something else holds it, in
// a restore, a reload and a save over a changed file. The reload that cannot read the file puts a folder where the file
// was, since macOS does not lock a file the way the Windows test does.

@MainActor
final class DocumentLossTests: XCTestCase {
    // A crash left the locked file behind with the password still needed to read it.
    private func crashedLocked(_ f: ViewModelFixture) -> RecoveryStore {
        let store = RecoveryStore(directory: f.folders.recovery)
        store.write(UUID(), Pdfs.fixture("locked.pdf"), RecoveryMeta(title: "locked.pdf", saved: Date()))
        store.flush()
        return store
    }

    func test_aRestoredFileThatAsksForAPasswordKeepsItsRecoveryCopyUntilItIsOpen() async {
        let f = ViewModelFixture(self)
        let store = crashedLocked(f)
        f.vm.checkRecovery()

        await f.vm.restore()

        XCTAssertNotNil(f.vm.passwordRequest)
        XCTAssertEqual(store.list().count, 1)
    }

    func test_givingUpAtThePasswordLeavesTheRecoveryCopyForTheNextStart() async {
        let f = ViewModelFixture(self)
        let store = crashedLocked(f)
        f.vm.checkRecovery()
        await f.vm.restore()

        f.vm.cancelPending()

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertEqual(store.list().count, 1)
        f.vm.checkRecovery()
        XCTAssertEqual(f.vm.recoveryOffer?.count, 1)
    }

    func test_onceTheRestoredFileIsOpenOneRecoveryCopyRemains() async {
        let f = ViewModelFixture(self)
        let store = crashedLocked(f)
        f.vm.checkRecovery()
        let old = f.vm.recoveryOffer!.first!.id
        await f.vm.restore()

        await f.vm.submitPassword("secret")

        XCTAssertEqual(f.vm.documents.count, 1)
        let tab = f.vm.documents[0]
        XCTAssertTrue(tab.isDirty)
        store.flush()
        XCTAssertEqual(store.list().map(\.id), [tab.id])
        XCTAssertNotEqual(old, tab.id)
    }

    func test_aRecoveryCopyThatCannotBeReadIsKept() async {
        let f = ViewModelFixture(self)
        let store = RecoveryStore(directory: f.folders.recovery)
        store.write(UUID(), Array("not a pdf".utf8), RecoveryMeta(title: "bad.pdf", saved: Date()))
        store.flush()
        f.vm.checkRecovery()

        await f.vm.restore()

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertEqual(store.list().count, 1)
    }

    func test_aReloadThatCannotReadTheFileKeepsTheTabAndItsChanges() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        let tab = f.vm.activeDocument!
        try Pdfs.retitle(tab.session, "Mine")
        try tab.commit("Properties")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        await f.vm.reload(tab)

        XCTAssertTrue(f.vm.activeDocument === tab)
        XCTAssertTrue(tab.isDirty)
        XCTAssertFalse((tab.renderer as! FakeRenderer).disposed)
        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertTrue(f.vm.recent.contains { samePath($0.url, url) })
    }

    func test_aReloadOfAHalfWrittenFileKeepsTheTab() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        let tab = f.vm.activeDocument!
        try touch(url, Array("%PDF-1.7\n".utf8))

        await f.vm.reload(tab)

        XCTAssertEqual(f.vm.documents.count, 1)
        XCTAssertTrue(f.vm.documents[0] === tab)
        XCTAssertEqual(f.vm.message?.isError, true)
    }

    func test_aReloadOfAProtectedFileUsesThePasswordTheTabWasOpenedWith() async throws {
        let f = ViewModelFixture(self)
        let url = f.locked()
        await f.vm.open(url)
        await f.vm.submitPassword("secret")
        let tab = f.vm.activeDocument!
        try touch(url, Pdfs.fixture("locked.pdf"))

        await f.vm.reload(tab)

        XCTAssertNil(f.vm.passwordRequest)
        XCTAssertEqual(f.vm.documents.count, 1)
        XCTAssertFalse(f.vm.documents[0] === tab)
        XCTAssertTrue(f.vm.activeDocument === f.vm.documents[0])
    }

    func test_savingOverAFileAnotherProgramChangedStopsAndAsks() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        let tab = f.vm.activeDocument!
        try Pdfs.retitle(tab.session, "Mine")
        try tab.commit("Properties")
        try touch(url, Pdfs.text(3))

        let saved = f.vm.save(tab)

        XCTAssertFalse(saved)
        XCTAssertEqual(f.vm.message?.title, "File changed")
        XCTAssertEqual(try PdfDocument.open(path: url.path).pages.count, 3)
        XCTAssertTrue(tab.isDirty)

        f.vm.message!.action!.run()

        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(DocumentMetadata.read(try PdfDocument.open(path: url.path)).title, "Mine")
    }

    func test_savingACleanTabOverAChangedFileAlsoAsks() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        try touch(url, Pdfs.text(2))

        XCTAssertFalse(f.vm.save(f.vm.activeDocument!))
        XCTAssertEqual(try PdfDocument.open(path: url.path).pages.count, 2)
    }

    func test_savingAFileThatWasDeletedWritesItAgain() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        try FileManager.default.removeItem(at: url)

        XCTAssertTrue(f.vm.save(f.vm.activeDocument!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_aRestoredCopyOfAFileThatChangedWhileTheAppWasDownIsNotSavedOverIt() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf("report.pdf")
        let seen = DiskStamp.of(url)!
        let store = RecoveryStore(directory: f.folders.recovery)
        store.write(UUID(), Pdfs.text(), RecoveryMeta(title: "report.pdf", originalPath: url.path, saved: Date(),
                                                      originalWrite: seen.write, originalLength: seen.length))
        store.flush()
        try touch(url, Pdfs.text(4))
        f.vm.checkRecovery()
        await f.vm.restore()

        XCTAssertFalse(f.vm.save(f.vm.activeDocument!))
        XCTAssertEqual(try PdfDocument.open(path: url.path).pages.count, 4)
    }

    func test_aFileWithNoPagesIsRefusedAtOpen() async {
        let f = ViewModelFixture(self)
        let text = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\ntrailer\n<< /Root 1 0 R /Size 3 >>\n%%EOF\n"
        let url = f.dir.file("empty.pdf", Array(text.utf8))

        await f.vm.open(url)

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertEqual(f.vm.message?.title, "Nothing to show")
    }
}
