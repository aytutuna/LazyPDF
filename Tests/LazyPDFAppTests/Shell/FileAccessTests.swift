import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Not in the Windows tests: a sandboxed platform starts access to a file before it is opened and must be told when the
// shell no longer holds it. Also the reload that two clicks start, and the recovery copy that finds its file again.

@MainActor
final class FileAccessTests: XCTestCase {
    func test_aFileThatIsOpenAlreadyReleasesTheSecondGrant() async {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        let grant = Grant()

        await f.vm.open(url, access: grant)

        XCTAssertEqual(grant.stops, 1)
    }

    func test_aFileThatCannotBeReadReleasesItsGrant() async {
        let f = ViewModelFixture(self)
        let grant = Grant()

        await f.vm.open(f.dir.sub("missing.pdf"), access: grant)

        XCTAssertEqual(grant.stops, 1)
    }

    func test_anOpenTabHoldsItsGrantUntilItIsClosed() async {
        let f = ViewModelFixture(self)
        let grant = Grant()
        await f.vm.open(f.pdf(), access: grant)

        XCTAssertEqual(grant.stops, 0)
        f.vm.close(f.vm.activeDocument!)

        XCTAssertEqual(grant.stops, 1)
    }

    func test_aFileWaitingForAPasswordKeepsItsGrantUntilItIsGivenUpOrOpened() async {
        let f = ViewModelFixture(self)
        let given = Grant(), kept = Grant()

        await f.vm.open(f.locked("a.pdf"), access: given)
        await f.vm.submitPassword("wrong")
        XCTAssertEqual(given.stops, 0)
        f.vm.cancelPending()
        XCTAssertEqual(given.stops, 1)

        await f.vm.open(f.locked("b.pdf"), access: kept)
        await f.vm.submitPassword("secret")
        XCTAssertEqual(f.vm.documents.count, 1)
        XCTAssertEqual(kept.stops, 0)
        f.vm.close(f.vm.activeDocument!)
        XCTAssertEqual(kept.stops, 1)
    }

    func test_aReloadKeepsTheGrantOfTheTabItReplaces() async {
        let f = ViewModelFixture(self)
        let grant = Grant()
        await f.vm.open(f.pdf(), access: grant)

        await f.vm.reload(f.vm.activeDocument!)

        XCTAssertEqual(f.vm.documents.count, 1)
        XCTAssertEqual(grant.stops, 0)
        f.vm.close(f.vm.activeDocument!)
        XCTAssertEqual(grant.stops, 1)
    }

    func test_leavingTheAppReleasesTheGrants() async {
        let f = ViewModelFixture(self)
        let grant = Grant()
        await f.vm.open(f.pdf(), access: grant)

        XCTAssertTrue(f.vm.requestExit())

        XCTAssertEqual(grant.stops, 1)
    }

    func test_twoReloadsAtOnceMakeOneTab() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = f.vm.activeDocument!

        async let first = f.vm.tryReload(tab)
        async let second = f.vm.tryReload(tab)
        _ = await (first, second)

        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_aRecoveredFileIsFoundThroughItsBookmarkAndKeepsAGrant() async throws {
        let f = ViewModelFixture(self)
        let moved = f.pdf("moved.pdf")
        let bookmark = Data(f.dir.sub("report.pdf").standardizedFileURL.path.utf8)
        f.bookmarks.moved[String(decoding: bookmark, as: UTF8.self)] = moved.standardizedFileURL.path
        try crash(f, RecoveryMeta(title: "report.pdf", originalPath: "/gone/report.pdf", saved: Date(), bookmark: bookmark))
        f.vm.checkRecovery()

        await f.vm.restore()

        XCTAssertTrue(samePath(f.vm.activeDocument?.url, moved))
        XCTAssertEqual(f.bookmarks.grants.count, 1)
        f.vm.close(f.vm.activeDocument!)
        XCTAssertEqual(f.bookmarks.grants[0].stops, 1)
    }

    func test_aRecoveredFileWhoseBookmarkIsLostAsksForAName() async throws {
        let f = ViewModelFixture(self)
        f.bookmarks.lost = true
        try crash(f, RecoveryMeta(title: "report.pdf", originalPath: f.pdf("report.pdf").path, saved: Date(), bookmark: Data([1])))
        f.vm.checkRecovery()

        await f.vm.restore()

        XCTAssertEqual(f.vm.documents.count, 1)
        XCTAssertTrue(AppViewModel.needsName(f.vm.activeDocument!))
    }

    func test_theRecoveryCopyOfAnOpenFileKeepsItsBookmark() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        try Pdfs.retitle(f.vm.activeDocument!.session, "Unsaved")
        try f.vm.activeDocument!.commit("Properties")
        f.vm.recovery.flush()

        let meta = RecoveryStore(directory: f.folders.recovery).list().first?.meta

        XCTAssertEqual(meta?.bookmark, f.bookmarks.make(url))
    }

    private func crash(_ f: ViewModelFixture, _ meta: RecoveryMeta) throws {
        let session = try PdfEditSession.open(Pdfs.text())
        let store = RecoveryStore(directory: f.folders.recovery)
        store.write(UUID(), session.current, meta)
        store.flush()
    }
}
