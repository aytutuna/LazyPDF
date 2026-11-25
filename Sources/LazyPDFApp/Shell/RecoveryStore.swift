import Foundation

// Follows windows/LazyPDF.App/Services/RecoveryStore.cs.

/// What a recovery file belongs to: the file it was opened from, if any, and when it was last written.
public struct RecoveryMeta: Codable, Equatable {
    public var title = ""
    public var originalPath: String?
    public var saved = Date(timeIntervalSince1970: 0)

    /// What the original looked like when it was read, to tell later whether it changed while the copy was kept.
    public var originalWrite: Date?
    public var originalLength: Int64 = 0

    /// The process that wrote the entry; one still running is not a crash.
    public var processId = 0

    /// When that process started, to tell it from a later one that was given the same id.
    public var started: Date?

    /// Gets the original file back in a sandbox, where its path alone is not enough.
    public var bookmark: Data?

    public init(title: String = "", originalPath: String? = nil, saved: Date = Date(timeIntervalSince1970: 0),
                originalWrite: Date? = nil, originalLength: Int64 = 0, processId: Int = 0,
                started: Date? = nil, bookmark: Data? = nil) {
        self.title = title
        self.originalPath = originalPath
        self.saved = saved
        self.originalWrite = originalWrite
        self.originalLength = originalLength
        self.processId = processId
        self.started = started
        self.bookmark = bookmark
    }

    private enum CodingKeys: String, CodingKey {
        case title, originalPath, saved, originalWrite, originalLength, processId, started, bookmark
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.decodeLenient(forKey: .title, default: title)
        originalPath = c.decodeLenient(forKey: .originalPath, default: originalPath)
        saved = c.decodeLenient(forKey: .saved, default: saved)
        originalWrite = c.decodeLenient(forKey: .originalWrite, default: originalWrite)
        originalLength = c.decodeLenient(forKey: .originalLength, default: originalLength)
        processId = c.decodeLenient(forKey: .processId, default: processId)
        started = c.decodeLenient(forKey: .started, default: started)
        bookmark = c.decodeLenient(forKey: .bookmark, default: bookmark)
    }
}

/// A document left in the recovery folder.
public struct RecoveryEntry: Equatable {
    public let id: UUID
    public let meta: RecoveryMeta
    public let pdf: URL
}

/// The open documents as they stood after the last edit, in the recovery folder: id.pdf is the file's bytes, id.json says
/// what it is. A document closed or saved on purpose has no entry, so one still there at the next start is what a crash
/// left. Writes go through a serial queue, so `flush` can wait for them where Windows waits for its worker task.
public final class RecoveryStore: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "lazypdf.recovery")
    private let lock = NSLock()
    private var waiting: [UUID: (bytes: [UInt8], meta: RecoveryMeta)] = [:]
    private var running = false

    public init(directory: URL) {
        self.directory = directory
    }

    /// Queues the bytes to be written; a newer write for the same document replaces one still waiting.
    public func write(_ id: UUID, _ bytes: [UInt8], _ meta: RecoveryMeta) {
        lock.lock()
        defer { lock.unlock() }
        waiting[id] = (bytes, meta)
        if !running {
            running = true
            queue.async { self.drain() }
        }
    }

    public func delete(_ id: UUID) {
        lock.lock()
        waiting[id] = nil
        lock.unlock()
        flush()
        for ext in ["pdf", "json"] {
            try? FileManager.default.removeItem(at: file(id, ext))
        }
    }

    /// Waits until everything queued is on disk.
    public func flush() {
        queue.sync {}
    }

    public func list() -> [RecoveryEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var entries: [RecoveryEntry] = []
        for meta in names where meta.pathExtension == "json" {
            let pdf = meta.deletingPathExtension().appendingPathExtension("pdf")
            guard let id = UUID(uuidString: meta.deletingPathExtension().lastPathComponent),
                  FileManager.default.fileExists(atPath: pdf.path) else { continue }
            if case .loaded(let value) = StoreFiles.read(RecoveryMeta.self, from: meta) {
                entries.append(RecoveryEntry(id: id, meta: value, pdf: pdf))
            }
        }
        return entries.sorted { $0.meta.saved > $1.meta.saved }
    }

    /// The entries whose process is gone: what a crash left, as opposed to the documents of an instance that is still open.
    public func abandoned() -> [RecoveryEntry] {
        list().filter { !ProcessCheck.isRunning($0.meta.processId, started: $0.meta.started) }
    }

    /// Removes what a crash or a full disk left: temporary files over an hour old, and a pdf or json whose partner has
    /// been missing for a day. A complete pair is never touched, whatever its age.
    public func sweep(now: Date = Date()) {
        let names = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in names {
            guard let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            let age = now.timeIntervalSince(written)
            let ext = url.pathExtension
            if ext != "pdf" && ext != "json" {
                if age > 3600 { try? FileManager.default.removeItem(at: url) }
                continue
            }
            let partner = url.deletingPathExtension().appendingPathExtension(ext == "pdf" ? "json" : "pdf")
            if age > 86400 && !FileManager.default.fileExists(atPath: partner.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (id, job) = waiting.first else {
                running = false
                lock.unlock()
                return
            }
            waiting[id] = nil
            lock.unlock()
            // Recovery is a courtesy: a full disk must not stop an edit.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? replace(file(id, "pdf"), Data(job.bytes))
            if let json = try? JSONEncoder().encode(job.meta) {
                try? replace(file(id, "json"), json)
            }
        }
    }

    private func replace(_ url: URL, _ data: Data) throws {
        try data.write(to: url, options: .atomic)
    }

    private func file(_ id: UUID, _ ext: String) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
    }
}
