import XCTest
@testable import LazyPDFApp

@MainActor
final class ReopenLastTests: XCTestCase {
    private func quit(_ f: ViewModelFixture) {
        f.vm.keep(f.vm.lastSession())
    }

    func test_offByDefaultAndNothingIsKept() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf("a.pdf"))

        quit(f)

        XCTAssertFalse(f.vm.reopenLast)
        XCTAssertTrue(AppPreferencesStore.load(f.folders.settings).lastFiles.isEmpty)
    }

    func test_theTabsAndTheirPagesComeBack() async {
        let f = ViewModelFixture(self)
        f.vm.setReopenLast(true)
        await f.vm.open(f.pdf("a.pdf", pages: 3))
        await f.vm.open(f.pdf("b.pdf", pages: 4))
        f.vm.documents[0].pageIndex = 2
        f.vm.documents[1].pageIndex = 1
        f.vm.select(f.vm.documents[0])
        quit(f)

        let next = f.makeViewModel()
        XCTAssertTrue(next.reopenLast)
        await next.reopenLastSession()

        XCTAssertEqual(next.documents.map(\.title), ["a.pdf", "b.pdf"])
        XCTAssertEqual(next.documents.map(\.pageIndex), [2, 1])
        XCTAssertTrue(next.activeDocument === next.documents[0])
    }

    func test_aFileThatIsGoneIsSkipped() async throws {
        let f = ViewModelFixture(self)
        f.vm.setReopenLast(true)
        let gone = f.pdf("gone.pdf")
        await f.vm.open(gone)
        await f.vm.open(f.pdf("kept.pdf"))
        quit(f)
        try FileManager.default.removeItem(at: gone)

        let next = f.makeViewModel()
        await next.reopenLastSession()

        XCTAssertEqual(next.documents.map(\.title), ["kept.pdf"])
        XCTAssertNil(next.message)
    }

    func test_turningItOffForgetsTheList() async {
        let f = ViewModelFixture(self)
        f.vm.setReopenLast(true)
        await f.vm.open(f.pdf("a.pdf"))
        quit(f)

        f.vm.setReopenLast(false)

        XCTAssertTrue(AppPreferencesStore.load(f.folders.settings).lastFiles.isEmpty)
        let next = f.makeViewModel()
        await next.reopenLastSession()
        XCTAssertTrue(next.documents.isEmpty)
    }

    func test_aCrashOfferComesFirst() async {
        let f = ViewModelFixture(self)
        f.vm.setReopenLast(true)
        await f.vm.open(f.pdf("a.pdf"))
        quit(f)
        let store = RecoveryStore(directory: f.folders.recovery)
        store.write(UUID(), Pdfs.text(), RecoveryMeta(title: "x.pdf", originalPath: nil, saved: Date()))
        store.flush()

        let next = f.makeViewModel()
        next.checkRecovery()
        await next.reopenLastSession()

        XCTAssertTrue(next.documents.isEmpty)
    }
}
