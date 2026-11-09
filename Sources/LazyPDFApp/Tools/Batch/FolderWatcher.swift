import Foundation

// Follows windows/LazyPDF.App/Tools/Batch/FolderWatcher.cs on the Mac. A watched folder is a security-scoped folder the person
// chose; the listing of it is read when the system says an entry came or went. iOS does not offer the watch: an app there gets
// no word of what appears in a folder it does not own.

public protocol FolderWatching: AnyObject {
    func stop()
}

/// Starts a watch on `folder`. `found` is called with each PDF that appears, once it can be opened; `failed` when the folder
/// goes away and the watch cannot say what appeared any more.
public typealias FolderWatchFactory = (_ folder: URL, _ found: @escaping @Sendable (URL) -> Void, _ failed: @escaping @Sendable () -> Void) throws -> FolderWatching

#if os(macOS)
/// Reports each PDF that appears in a folder once it has stopped changing for a moment. A file that goes on changing after it
/// was reported, because its copy stalled or it was written over in place, is reported again when it settles, and one that
/// leaves the folder and comes back is new. Files already there are not reported. The callbacks come on a queue of the
/// watcher's own.
public final class FolderWatcher: FolderWatching, @unchecked Sendable {
    private struct Stamp: Equatable {
        let size: Int
        let modified: Date
    }

    private struct Seen {
        let stamp: Stamp
        let since: Date
    }

    private let folder: URL
    private let delay: TimeInterval
    private let found: @Sendable (URL) -> Void
    private let failed: @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.lazypdf.folderwatcher")
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var known: [String: Stamp] = [:]
    private var waiting: [String: Seen] = [:]
    private var stopped = false

    public static let factory: FolderWatchFactory = { folder, found, failed in
        try FolderWatcher(folder: folder, found: found, failed: failed)
    }

    public init(folder: URL, delay: TimeInterval = 1.5, found: @escaping @Sendable (URL) -> Void, failed: @escaping @Sendable () -> Void) throws {
        self.folder = folder
        self.delay = delay
        self.found = found
        self.failed = failed
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        known = listing()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler { [weak self] in self?.changed(source.data) }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
        // Writing into a file raises no event on its folder, so a file that is still growing or is written over is found by looking.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay / 2, repeating: delay / 2)
        timer.setEventHandler { [weak self] in self?.scan() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        queue.sync {
            stopped = true
            source?.cancel()
            source = nil
            timer?.cancel()
            timer = nil
            waiting = [:]
        }
    }

    deinit {
        source?.cancel()
        timer?.cancel()
    }

    private func listing() -> [String: Stamp] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        var found: [String: Stamp] = [:]
        for file in files where file.pathExtension.lowercased() == "pdf" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            found[file.lastPathComponent] = Stamp(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
        }
        return found
    }

    private func changed(_ events: DispatchSource.FileSystemEvent) {
        if stopped { return }
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            failed()
            return
        }
        scan()
    }

    // A name that is no longer listed is forgotten, so the same file put back is run again.
    private func scan() {
        if stopped { return }
        let now = listing()
        let date = Date()
        known = known.filter { now[$0.key] != nil }
        waiting = waiting.filter { now[$0.key] != nil }
        for (name, stamp) in now where known[name] != stamp {
            guard let seen = waiting[name], seen.stamp == stamp else {
                waiting[name] = Seen(stamp: stamp, since: date)
                continue
            }
            let file = folder.appendingPathComponent(name)
            if date.timeIntervalSince(seen.since) >= delay && stamp.size > 0 && FileManager.default.isReadableFile(atPath: file.path) {
                waiting[name] = nil
                known[name] = stamp
                found(file)
            }
        }
    }
}
#endif
