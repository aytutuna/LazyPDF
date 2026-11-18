import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The rules the Mac's window hub follows: one primary however the windows come back, a move that waits for its window, and
// an exit that several windows agree on before any of them lets go of its tabs.

@MainActor
final class WindowRosterTests: XCTestCase {
    func test_theFirstWindowWithNoValueIsThePrimary() {
        let roster = WindowRoster()

        let first = roster.claim(nil)

        XCTAssertEqual(first.role, .primary)
        XCTAssertEqual(roster.primary, first.id)
    }

    func test_aSecondWindowWithNoValueClosesItself() {
        let roster = WindowRoster()
        _ = roster.claim(nil)

        XCTAssertEqual(roster.claim(nil).role, .closed)
    }

    func test_aRestoredWindowTheHubDoesNotKnowIsThePrimaryOnlyWhenThereIsNone() {
        let roster = WindowRoster()
        let old = UUID()

        let first = roster.claim(old)
        let second = roster.claim(UUID())

        XCTAssertEqual(first.role, .primary)
        XCTAssertEqual(first.id, old)
        XCTAssertEqual(second.role, .closed)
    }

    func test_oneWindowAskedForTwiceKeepsItsRole() {
        let roster = WindowRoster()
        let first = roster.claim(nil)

        XCTAssertEqual(roster.claim(first.id).role, .primary)
        XCTAssertEqual(roster.claim(first.id).id, first.id)
    }

    func test_thePrimaryKeepsItsIdWhenItsWindowIsGone() {
        let roster = WindowRoster()
        let first = roster.claim(nil)
        roster.release(first.id)

        XCTAssertEqual(roster.claim(first.id).role, .primary)
        XCTAssertEqual(roster.claim(nil).role, .closed)
    }

    func test_filesThatArriveBeforeAnyWindowGetThePrimaryItsWindowThenTakes() {
        let roster = WindowRoster()

        let early = roster.reservePrimary()
        let window = roster.claim(nil)

        XCTAssertEqual(window.id, early)
        XCTAssertEqual(window.role, .primary)
        XCTAssertEqual(roster.claim(nil).role, .closed)
        XCTAssertEqual(roster.reservePrimary(), early)
    }

    func test_aRestoredWindowTakesTheReservedPrimary() {
        let roster = WindowRoster()
        let early = roster.reservePrimary()

        let restored = roster.claim(UUID())

        XCTAssertEqual(restored.id, early)
        XCTAssertEqual(restored.role, .primary)
    }

    func test_neverMoreThanOnePrimary() {
        let roster = WindowRoster()
        let values: [UUID?] = [nil, UUID(), nil, UUID(), nil]

        let roles = values.map { roster.claim($0).role }

        XCTAssertEqual(roles.filter { $0 == .primary }.count, 1)
    }

    @MainActor
    private struct Windows {
        let f: ViewModelFixture
        let registry = DocumentRegistry()
        let roster = WindowRoster()
        let a: AppViewModel
        let b: AppViewModel

        init(_ test: XCTestCase) {
            f = ViewModelFixture(test)
            a = f.makeViewModel(registry: registry)
            b = f.makeViewModel(registry: registry)
        }
    }

    func test_aParkedMoveHappensWhenItsWindowHasAViewModel() async throws {
        let w = Windows(self)
        _ = w.roster.claim(nil)
        await w.a.open(w.f.pdf())
        let tab = try XCTUnwrap(w.a.activeDocument)
        let id = w.roster.park(tab, from: w.a, at: 1)

        XCTAssertEqual(w.roster.claim(id).role, .secondary)
        XCTAssertEqual(w.roster.arrived(id, w.b, registry: w.registry), true)

        XCTAssertTrue(w.b.documents.first === tab)
        XCTAssertTrue(w.a.documents.isEmpty)
    }

    func test_aParkedMoveThatIsRefusedByNowLeavesTheTabAlone() async throws {
        let w = Windows(self)
        await w.a.open(w.f.pdf())
        let tab = try XCTUnwrap(w.a.activeDocument)
        let id = w.roster.park(tab, from: w.a, at: 1)
        w.a.actionRunning = true

        XCTAssertEqual(w.roster.arrived(id, w.b, registry: w.registry), false)

        XCTAssertTrue(w.a.documents.first === tab)
        XCTAssertTrue(w.b.documents.isEmpty)
    }

    func test_aWindowThatNeverOpenedTakesNothing() async throws {
        let w = Windows(self)
        await w.a.open(w.f.pdf())
        let tab = try XCTUnwrap(w.a.activeDocument)
        let id = w.roster.park(tab, from: w.a, at: 1)

        w.roster.forget(id)

        XCTAssertNil(w.roster.arrived(id, w.b, registry: w.registry))
        XCTAssertTrue(w.a.documents.first === tab)
    }

    func test_aWindowWithNoParkedMoveStartsEmpty() {
        let w = Windows(self)

        XCTAssertNil(w.roster.arrived(UUID(), w.b, registry: w.registry))
        XCTAssertTrue(w.b.documents.isEmpty)
    }

    // The exit of several windows: nothing is closed until every window has been answered for.

    func test_anExitThatKeepsTheTabsAsksWithoutClosingAnything() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf("clean.pdf"))
        let clean = try XCTUnwrap(f.vm.activeDocument)

        XCTAssertTrue(f.vm.requestExit(dispose: false))

        XCTAssertFalse(f.renderers[0].disposed)
        XCTAssertTrue(f.vm.documents.first === clean)
        f.vm.closeAllTabs()
        XCTAssertTrue(f.renderers[0].disposed)
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_cancellingTheQuestionOfALaterWindowLeavesTheEarlierOnesOpen() async throws {
        let w = Windows(self)
        await w.a.open(w.f.pdf("one.pdf"))
        await w.b.open(w.f.pdf("two.pdf"))
        let two = try XCTUnwrap(w.b.activeDocument)
        try Pdfs.retitle(two.session, "Changed")
        try two.commit("Properties")

        XCTAssertTrue(w.a.requestExit(dispose: false))
        XCTAssertFalse(w.b.requestExit(dispose: false))
        XCTAssertTrue(w.b.closeQuestion === two)
        w.b.cancelClose()

        XCTAssertFalse(w.f.renderers.contains { $0.disposed })
        XCTAssertEqual(w.a.documents.count, 1)
        XCTAssertEqual(w.b.documents.count, 1)
    }

    func test_theLastAnswerOfAKeptExitStillTellsTheShell() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = try XCTUnwrap(f.vm.activeDocument)
        try Pdfs.retitle(tab.session, "Changed")
        try tab.commit("Properties")
        let done = Counter()
        f.vm.exitRequested = { done.count += 1 }
        XCTAssertFalse(f.vm.requestExit(dispose: false))

        f.vm.close(tab)

        XCTAssertEqual(done.count, 1)
    }

    func test_aWindowThatIsNotTheFirstDoesNotOfferTheCrashLeftovers() async throws {
        let f = ViewModelFixture(self)
        let store = RecoveryStore(directory: f.folders.recovery)
        store.write(UUID(), Pdfs.text(), RecoveryMeta(title: "left.pdf", saved: Date(), processId: Int(Int32.max)))
        store.flush()
        let second = f.makeViewModel()
        second.offersRecovery = false

        second.checkRecovery()
        f.vm.checkRecovery()

        XCTAssertNil(second.recoveryOffer)
        XCTAssertEqual(f.vm.recoveryOffer?.count, 1)
    }
}
