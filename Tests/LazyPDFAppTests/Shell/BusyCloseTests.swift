import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/BusyCloseTests.cs: a job edits the document off the main actor, so the window neither
// closes nor saves what it holds meanwhile. Latches stand in for the TaskCompletionSources, so nothing waits on a clock.

@MainActor
final class BusyCloseTests: XCTestCase {
    private func startJob(_ vm: AppViewModel) async -> (run: Task<Void, Error>, finish: Latch) {
        let started = Latch()
        let finish = Latch()
        let run = Task {
            try await vm.runBusy("Working") { _ in
                started.release()
                await finish.wait()
            }
        }
        await started.wait()
        return (run, finish)
    }

    func test_closingATabWaitsForTheJob() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = f.vm.activeDocument!
        try Pdfs.retitle(tab.session, "x")
        try tab.commit("x")
        let (run, finish) = await startJob(f.vm)

        XCTAssertFalse(f.vm.requestClose(tab))

        XCTAssertNil(f.vm.closeQuestion)
        XCTAssertEqual(f.vm.message?.title, "Still working")
        XCTAssertTrue(f.vm.documents.contains { $0 === tab })
        finish.release()
        try await run.value
        XCTAssertFalse(f.vm.requestClose(tab))
        XCTAssertTrue(f.vm.closeQuestion === tab)
    }

    func test_closingTheWindowWaitsForTheJob() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let exits = Counter()
        f.vm.exitRequested = { exits.count += 1 }
        let (run, finish) = await startJob(f.vm)

        XCTAssertFalse(f.vm.requestExit())

        XCTAssertEqual(exits.count, 0)
        XCTAssertTrue(f.renderers.allSatisfy { !$0.disposed })
        finish.release()
        try await run.value
        XCTAssertTrue(f.vm.requestExit())
    }

    func test_aSecondJobKeepsTheBusyBarWhenTheFirstEnds() async throws {
        let f = ViewModelFixture(self)
        let (first, endFirst) = await startJob(f.vm)
        let (second, endSecond) = await startJob(f.vm)

        endFirst.release()
        try await first.value
        XCTAssertTrue(f.vm.isBusy)

        endSecond.release()
        try await second.value
        XCTAssertFalse(f.vm.isBusy)
    }

    func test_cancellingEndsTheJobAndSaysSo() async throws {
        let f = ViewModelFixture(self)
        let started = Latch()
        let vm = f.vm!
        let run = Task {
            try await vm.runBusy("Working") { token in
                started.release()
                while !token.isCancelled { await Task.yield() }
                try token.throwIfCancelled()
            }
        }
        await started.wait()

        f.vm.cancelBusy()
        try await run.value

        XCTAssertEqual(f.vm.statusFull, "Cancelled.")
        XCTAssertFalse(f.vm.isBusy)
    }
}
