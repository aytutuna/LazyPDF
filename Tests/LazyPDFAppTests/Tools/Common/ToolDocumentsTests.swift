import Foundation
import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The helpers the tools share for work off the main actor. Windows has WaitAsync(token) and OpenCopy.Of; Swift tests them
// directly since they are not behind a Windows test of their own.

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return on
    }

    func set(_ now: Bool) {
        lock.lock()
        on = now
        lock.unlock()
    }
}

private final class Gate: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
}

@MainActor
final class ToolDocumentsTests: XCTestCase {
    func test_aJobThatEndsGivesItsResult() async throws {
        let value = try await ToolDocuments.run(CancelToken()) { 7 }

        XCTAssertEqual(value, 7)
    }

    func test_aJobThatThrowsThrowsItsError() async {
        struct Failed: Error {}
        do {
            _ = try await ToolDocuments.run(CancelToken()) { () -> Int in throw Failed() }
            XCTFail("the error was lost")
        } catch {
            XCTAssertTrue(error is Failed)
        }
    }

    func test_cancellingReturnsAtOnceWhileTheJobIsStillRunning() async throws {
        let token = CancelToken()
        let gate = Gate()
        let started = Date()
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            token.cancel()
        }

        do {
            _ = try await ToolDocuments.run(token) { () -> Int in
                _ = gate.semaphore.wait(timeout: .now() + 20)
                return 1
            }
            XCTFail("the job's end was waited for")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        gate.semaphore.signal()
    }

    func test_cancellingReachesTheJobsOwnTask() async throws {
        let token = CancelToken()
        let seen = Flag()
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            token.cancel()
        }

        _ = try? await ToolDocuments.run(token) { () -> Int in
            let until = Date().addingTimeInterval(10)
            while !Task.isCancelled && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
            seen.set(Task.isCancelled)
            return 1
        }

        await waitUntil { seen.value }
        XCTAssertTrue(seen.value)
    }

    func test_aCopyIsTheFileAsItWasWhenTheCopyWasMade() async throws {
        let rig = try ToolRig()
        let copy = OpenCopy.of(rig.tab, rig.host)
        let before = rig.tab.session.current

        try TestPdfs.retitle(rig.tab.session, "Changed")
        _ = try rig.tab.commit("Properties")

        let document = try copy()
        XCTAssertEqual(document.pages.count, 2)
        XCTAssertNotEqual(rig.tab.session.current, before)
        XCTAssertNotEqual(DocumentMetadata.read(document).title, "Changed")
    }
}
