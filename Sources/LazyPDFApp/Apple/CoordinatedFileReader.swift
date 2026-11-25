#if canImport(Darwin)
import Foundation

// The reading side of CoordinatedFileWriter: a file a provider keeps in the cloud is fetched before it is read, and a read
// does not meet a write half way.

public enum CoordinatedFileReader {
    public static func read(_ url: URL) throws -> Data {
        var result: Result<Data, Error>?
        var refused: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &refused) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let refused { throw refused }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
#endif
