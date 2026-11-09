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
/// Reports each PDF that appears in a folder once it has stopped changing for a moment: a file that is still being copied is
/// looked at again until its writer lets go. Files already there are not reported. The callbacks come on a queue of the
/// watcher's own.
public final class FolderWatcher: FolderWatching, @unchecked Sendable {
    private struct Stamp: Equatable {
        let size: Int
        let modified: Date
    }

    private let folder: URL
    private let delay: TimeInterval
    private let found: @Sendable (URL) -> Void
    private let failed: @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.lazypdf.folderwatcher")
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var known: [String: Stamp] = [:]
    private var waiting: [String: Stamp] = [:]
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
        for (name, stamp) in listing() where known[name] != stamp {
            waiting[name] = stamp
        }
        schedule()
    }

    private func schedule() {
        guard !waiting.isEmpty else { return }
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.check() }
        self.timer = timer
        timer.resume()
    }

    private func check() {
        if stopped { return }
        let now = listing()
        for (name, noted) in waiting {
            guard let stamp = now[name] else {
                waiting[name] = nil
                continue
            }
            if stamp == noted && stamp.size > 0 && FileManager.default.isReadableFile(atPath: folder.appendingPathComponent(name).path) {
                waiting[name] = nil
                known[name] = stamp
                found(folder.appendingPathComponent(name))
            } else {
                waiting[name] = stamp
            }
        }
        schedule()
    }
}
#endif
