#if os(iOS)
import Foundation
import LazyPDFApp

// The iPhone and iPad edit a file where another provider keeps it, so the write goes through a file coordinator: the
// provider is told, and nobody reads half a file. The file is finished in a folder of the app first (the engine checks
// that it reads back), then put in the file's place.

public struct CoordinatedFileWriter: FileWriter {
    public init() {}

    public func write(to url: URL, _ write: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let staged = work.appendingPathComponent(url.lastPathComponent)
        try write(staged)

        var failure: Error?
        var refused: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &refused) { target in
            do {
                if manager.fileExists(atPath: target.path) {
                    _ = try manager.replaceItemAt(target, withItemAt: staged)
                } else {
                    try manager.moveItem(at: staged, to: target)
                }
            } catch {
                failure = error
            }
        }
        if let refused { throw refused }
        if let failure { throw failure }
    }
}
#endif
