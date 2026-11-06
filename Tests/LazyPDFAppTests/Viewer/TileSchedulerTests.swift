import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/TileSchedulerTests.cs: the queue of tiles to draw, nearest first, dropped when wanted no more.

final class TileSchedulerTests: XCTestCase {
    private func tile(_ page: Int) -> TileSpec {
        TileSpec(TileKey(page, 0, 1, 0, 0, .none), 0, 0, 4, 4)
    }

    private let image = PdfRgbaImage(1, 1, [0, 0, 0, 255])

    private final class Log<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []

        func add(_ item: T) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }

        var all: [T] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    // A renderer that holds every tile until the test lets it go.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [(page: Int, resume: CheckedContinuation<PdfRgbaImage?, Never>)] = []
        private var finished: Set<Int> = []
        private let image: PdfRgbaImage

        init(_ image: PdfRgbaImage) {
            self.image = image
        }

        var started: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return held.map { $0.page }
        }

        func render(_ spec: TileSpec) async -> PdfRgbaImage? {
            await withCheckedContinuation { resume in
                lock.lock()
                held.append((spec.key.page, resume))
                lock.unlock()
            }
        }

        func finishAll() {
            lock.lock()
            let all = held.filter { !finished.contains($0.page) }
            held.removeAll()
            lock.unlock()
            for item in all { item.resume.resume(returning: nil) }
        }

        func finish(_ page: Int) {
            lock.lock()
            let resume = held.first { $0.page == page }?.resume
            finished.insert(page)
            lock.unlock()
            resume?.resume(returning: image)
        }
    }

    private func makeScheduler(_ gate: Gate, workers: Int, delivered: Log<Int>? = nil) -> TileScheduler {
        TileScheduler(workers: workers, render: { await gate.render($0) }, done: { spec, _ in delivered?.add(spec.key.page) })
    }

    func test_theLowestPriorityNumberIsDrawnFirst() async {
        let gate = Gate(image)
        let scheduler = makeScheduler(gate, workers: 1)
        defer { scheduler.dispose(); gate.finishAll() }

        scheduler.want([(tile(1), 30), (tile(2), 10), (tile(3), 20)])
        await until { gate.started.count == 1 }
        gate.finish(2)
        await until { gate.started.count == 2 }
        gate.finish(3)
        await until { gate.started.count == 3 }

        XCTAssertEqual(gate.started, [2, 3, 1])
    }

    func test_whatIsNotWantedAnyMoreIsNeverDrawn() async {
        let gate = Gate(image)
        let scheduler = makeScheduler(gate, workers: 1)
        defer { scheduler.dispose(); gate.finishAll() }
        scheduler.want([(tile(1), 1), (tile(2), 2), (tile(3), 3)])
        await until { gate.started.count == 1 }

        scheduler.want([(tile(3), 1)])
        gate.finish(1)
        await until { gate.started.count == 2 }

        XCTAssertEqual(gate.started, [1, 3])
    }

    func test_aTileBeingDrawnWhenItIsDroppedIsFinishedButNotDelivered() async {
        let gate = Gate(image)
        let delivered = Log<Int>()
        let scheduler = makeScheduler(gate, workers: 1, delivered: delivered)
        defer { scheduler.dispose(); gate.finishAll() }
        scheduler.want([(tile(1), 1), (tile(2), 2)])
        await until { gate.started.count == 1 }

        scheduler.want([(tile(2), 1)])
        gate.finish(1)
        await until { gate.started.count == 2 }
        gate.finish(2)
        await until { scheduler.pending == 0 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(delivered.all, [2])
    }

    func test_aTileWantedAgainWhileBeingDrawnIsStillDelivered() async {
        let gate = Gate(image)
        let delivered = Log<Int>()
        let scheduler = makeScheduler(gate, workers: 1, delivered: delivered)
        defer { scheduler.dispose(); gate.finishAll() }
        scheduler.want([(tile(1), 1)])
        await until { gate.started.count == 1 }
        scheduler.want([])

        scheduler.want([(tile(1), 1)])
        gate.finish(1)
        await until { delivered.all.count == 1 }

        XCTAssertEqual(gate.started.count, 1)
    }

    func test_severalWorkersDrawAtTheSameTime() async {
        let gate = Gate(image)
        let scheduler = makeScheduler(gate, workers: 3)
        defer { scheduler.dispose(); gate.finishAll() }

        scheduler.want([(tile(1), 1), (tile(2), 2), (tile(3), 3), (tile(4), 4)])

        await until { gate.started.count == 3 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(gate.started.count, 3)
        XCTAssertEqual(scheduler.queued, 1)
    }

    func test_aTileThatCannotBeDrawnIsDeliveredAsNil() async {
        let result = Log<Bool>()
        let scheduler = TileScheduler(workers: 1, render: { _ in nil }, done: { _, image in result.add(image == nil) })
        defer { scheduler.dispose() }

        scheduler.want([(tile(1), 1)])

        await until { !result.all.isEmpty }
        XCTAssertEqual(result.all, [true])
    }

    func test_aRendererThatThrowsDoesNotStopTheWorker() async {
        struct Broken: Error {}
        let delivered = Log<Int>()
        let image = image
        let scheduler = TileScheduler(workers: 1, render: { spec in
            if spec.key.page == 1 { throw Broken() }
            return image
        }, done: { spec, _ in delivered.add(spec.key.page) })
        defer { scheduler.dispose() }

        scheduler.want([(tile(1), 1), (tile(2), 2)])

        await until { delivered.all.contains(2) }
    }
}
