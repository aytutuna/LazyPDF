import Foundation
import LazyPDFKit

// Port of windows/LazyPDF.App/Viewer/TileScheduler.cs on Swift concurrency: a worker is a task started when there is work
// and a free slot, instead of a loop waiting on a semaphore.

/// Draws wanted tiles a few at a time, lowest priority number first. Each `want` replaces the whole list: what is no longer
/// in it is dropped from the queue, or, if already being drawn, finished and thrown away, so tiles that scrolled out of
/// reach cost nothing but the ones in flight.
public final class TileScheduler: @unchecked Sendable {
    private final class Entry {
        let spec: TileSpec
        var priority: Double
        var running = false
        var dropped = false
        var finished = false
        var task: Task<Void, Never>?

        init(_ spec: TileSpec, _ priority: Double) {
            self.spec = spec
            self.priority = priority
        }
    }

    private let lock = NSLock()
    private var entries: [TileKey: Entry] = [:]
    private var inFlight: [ObjectIdentifier: Entry] = [:]
    private var stopped = false
    private let render: @Sendable (TileSpec) async throws -> PdfRgbaImage?
    private let done: @Sendable (TileSpec, PdfRgbaImage?) -> Void
    private let workers: Int

    /// `render` draws one tile and may be called for several at once; it should return early when its task is cancelled.
    /// `done` gets each finished tile (nil when it could not be drawn) on a task of its own, never on the caller's thread.
    public init(workers: Int = 3, render: @escaping @Sendable (TileSpec) async throws -> PdfRgbaImage?,
                done: @escaping @Sendable (TileSpec, PdfRgbaImage?) -> Void) {
        self.workers = workers
        self.render = render
        self.done = done
    }

    /// Tiles waiting for a worker.
    public var queued: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { !$0.running }.count
    }

    /// Tiles being drawn and tiles waiting.
    public var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { !$0.dropped }.count
    }

    /// Makes `wanted` the work to do; a lower priority number is drawn sooner.
    public func want(_ wanted: [(spec: TileSpec, priority: Double)]) {
        lock.lock()
        let keep = Set(wanted.map { $0.spec.key })
        for entry in Array(entries.values) where !keep.contains(entry.spec.key) {
            if entry.running { entry.dropped = true } else { entries[entry.spec.key] = nil }
        }
        for (spec, priority) in wanted {
            if let entry = entries[spec.key] {
                entry.priority = priority
                entry.dropped = false
            } else {
                entries[spec.key] = Entry(spec, priority)
            }
        }
        lock.unlock()
        fill()
    }

    /// Stops the work: tiles waiting are forgotten and the ones being drawn are cancelled and not delivered.
    public func dispose() {
        lock.lock()
        stopped = true
        entries.removeAll()
        let live = inFlight.values.compactMap { $0.task }
        lock.unlock()
        for task in live { task.cancel() }
    }

    // Starts a task for the best waiting tile for as long as a slot is free.
    private func fill() {
        while let entry = take() {
            let task = Task.detached { [self] in
                var image: PdfRgbaImage?
                do {
                    image = try await render(entry.spec)
                } catch {
                    image = nil
                }
                finish(entry, image)
            }
            lock.lock()
            if stopped { task.cancel() } else if !entry.finished { entry.task = task }
            lock.unlock()
        }
    }

    private func take() -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, inFlight.count < workers else { return nil }
        var next: Entry?
        for entry in entries.values where !entry.running {
            if next == nil || entry.priority < next!.priority { next = entry }
        }
        if let next {
            next.running = true
            inFlight[ObjectIdentifier(next)] = next
        }
        return next
    }

    private func finish(_ entry: Entry, _ image: PdfRgbaImage?) {
        lock.lock()
        let dropped = entry.dropped
        if entries[entry.spec.key] === entry { entries[entry.spec.key] = nil }
        entry.finished = true
        entry.task = nil
        inFlight[ObjectIdentifier(entry)] = nil
        let deliver = !dropped && !stopped
        lock.unlock()
        if deliver { done(entry.spec, image) }
        fill()
    }
}
