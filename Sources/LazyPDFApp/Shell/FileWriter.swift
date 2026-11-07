import Foundation

// No Windows twin: a Windows program writes a file where it lies. On iOS a file from another provider has to be written
// inside a file coordination, which the iOS shell does; everywhere else the file is written as it is.

/// How a document's file gets written. `write` makes the finished file at the path it is given, and afterwards the file
/// is at `url`.
public protocol FileWriter {
    func write(to url: URL, _ write: (URL) throws -> Void) throws
}

/// Writes at `url` itself.
public struct PlainFileWriter: FileWriter {
    public init() {}

    public func write(to url: URL, _ write: (URL) throws -> Void) throws {
        try write(url)
    }
}
