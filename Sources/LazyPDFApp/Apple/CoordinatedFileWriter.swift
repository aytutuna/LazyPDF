#if canImport(Darwin)
import Foundation

// The iPhone and iPad edit a file where another provider keeps it, so the write goes through a file coordinator: the
// provider is told, and nobody reads half a file. The sandboxed Mac needs the same writer for another reason: it may touch
// the file it was handed but not its folder, and the item-replacement folder is the one place beside it that it can use.
// The file is finished there first (the engine checks that it reads back), then put in the file's place.

public struct CoordinatedFileWriter: FileWriter {
    public init() {}

    public func write(to url: URL, _ write: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let work = try Self.workFolder(for: url)
        defer { try? manager.removeItem(at: work) }
        let staged = work.appendingPathComponent(url.lastPathComponent)
        try write(staged)

        var failure: Error?
        var refused: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &refused) { target in
            do {
                if manager.fileExists(atPath: target.path) {
                    // The swap ignores the file's own permissions, which the engine's saver and Windows respect.
                    if !manager.isWritableFile(atPath: target.path) {
                        throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: target.path])
                    }
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

    // On the file's own volume the swap stays atomic (a file on a card or a drive is not on the app's); the app's folder
    // serves when the system will not make one there.
    private static func workFolder(for url: URL) throws -> URL {
        let manager = FileManager.default
        if let beside = try? manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true) {
            return beside
        }
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }
}
#endif
