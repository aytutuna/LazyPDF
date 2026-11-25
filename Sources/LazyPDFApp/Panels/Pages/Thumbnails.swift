import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/Thumbnails.cs.

/// Pictures of the first page of the files on the Home tab, kept as PNGs in the thumbnails folder under a name made from
/// the file's path, size and time, so a changed file gets a new one. The name starts with a hash of the path alone, so
/// the pictures of one file can be found and removed when it leaves the recent list.
public final class Thumbnails: @unchecked Sendable {
    private static let keepFor: TimeInterval = 60 * 24 * 3600
    private static let largest: Int64 = 64 * 1024 * 1024

    private let renderers: () -> DocumentRenderer
    private let directory: URL
    private let gate = DrawGate()
    private let lock = NSLock()
    private var generation = 0

    public init(_ renderers: @escaping () -> DocumentRenderer, directory: URL) {
        self.renderers = renderers
        self.directory = directory
        prune()
    }

    /// The PNG of the first page, `width` pixels wide; nil when the file cannot be opened without a password or drawn.
    public func get(_ url: URL, width: Int = 224) async -> [UInt8]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let length = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let ticks = Int64(modified.timeIntervalSince1970 * 10_000_000)
        if length > Self.largest { return nil }
        let cached = directory.appendingPathComponent(Self.pathHash(url) + "-" + Self.name("\(url.standardizedFileURL.path)|\(length)|\(ticks)|\(width)") + ".png")
        if let bytes = try? Data(contentsOf: cached) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
            return [UInt8](bytes)
        }
        let started = lock.withLock { generation }
        await gate.enter()
        let drawn = draw(url, width)
        await gate.leave()
        guard let png = drawn else { return nil }
        // Written under the lock, so a forget that comes after the check cannot miss the file.
        lock.withLock {
            guard generation == started else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(png).write(to: cached)
            } catch {}
        }
        return png
    }

    /// Removes the pictures of one file.
    public func forget(_ url: URL) {
        let prefix = Self.pathHash(url) + "-"
        lock.withLock {
            generation += 1
            remove { $0.lastPathComponent.hasPrefix(prefix) }
        }
    }

    public func clear() {
        lock.withLock {
            generation += 1
            remove { _ in true }
        }
    }

    private func remove(where matches: (URL) -> Bool) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "png" && matches(file) { try? FileManager.default.removeItem(at: file) }
    }

    private func draw(_ url: URL, _ width: Int) -> [UInt8]? {
        do {
            let session = try PdfEditSession.open(path: url.path)
            if session.document.isEncrypted { return nil }
            let renderer = renderers()
            defer { renderer.close() }
            guard renderer.load(session, nil) else { return nil }
            let wide = renderer.pageSize(0).width
            guard wide > 0, let image = renderer.render(0, Double(width) / (wide / 72)) else { return nil }
            return try PngWriter.encode(image)
        } catch {
            return nil
        }
    }

    private static func pathHash(_ url: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.standardizedFileURL.path.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }

    // Not a security hash: the name only has to differ when the file does. Two FNV-1a runs make 128 bits.
    private static func name(_ key: String) -> String {
        var a: UInt64 = 0xcbf29ce484222325
        var b: UInt64 = 0x6c62272e07bb0142
        for byte in key.utf8 {
            a = (a ^ UInt64(byte)) &* 0x100000001b3
            b = (b &* 0x100000001b3) ^ UInt64(byte)
        }
        return String(format: "%016llx%016llx", a, b)
    }

    private func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == "png" {
            guard let used = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if Date().timeIntervalSince(used) > Self.keepFor { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// Lets two pictures be drawn at a time; each draw opens its whole file.
private actor DrawGate {
    private var free = 2
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}
