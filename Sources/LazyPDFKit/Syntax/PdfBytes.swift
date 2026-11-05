import Foundation

// Twin of windows/LazyPDF.Core/Syntax/PdfBytes.cs: what a lexer reads, and the error a file it cannot use raises.

/// The bytes a lexer reads: a whole array, or a seekable file read in blocks as needed.
public protocol PdfBytes: AnyObject {
    var length: Int { get }

    /// The byte at `position`; -1 past the end.
    subscript(position: Int) -> Int { get }

    /// Up to `count` bytes from `position` (fewer at the end).
    func read(_ position: Int, _ count: Int) -> [UInt8]
}

public final class PdfArrayBytes: PdfBytes {
    private let bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var length: Int { bytes.count }

    public subscript(position: Int) -> Int {
        position >= 0 && position < bytes.count ? Int(bytes[position]) : -1
    }

    public func read(_ position: Int, _ count: Int) -> [UInt8] {
        if position < 0 || position >= bytes.count || count <= 0 { return [] }
        let n = min(count, bytes.count - position)
        return Array(bytes[position..<position + n])
    }
}

/// A seekable file read through a few cached 64 KB blocks, so a large file is never read whole.
/// A block that cannot be read reads as the end of the file.
public final class PdfStreamBytes: PdfBytes {
    private static let blockSize = 1 << 16
    private static let cachedBlocks = 16
    private let file: FileHandle
    private var blocks: [Int: [UInt8]] = [:]
    private var recent: [Int] = []

    public let length: Int

    public init(file: FileHandle) throws {
        self.file = file
        length = Int(clamping: try file.seekToEnd())
    }

    public subscript(position: Int) -> Int {
        if position < 0 || position >= length { return -1 }
        let block = loadBlock(position / Self.blockSize)
        let index = position % Self.blockSize
        return index < block.count ? Int(block[index]) : -1
    }

    public func read(_ position: Int, _ count: Int) -> [UInt8] {
        if position < 0 || position >= length || count <= 0 { return [] }
        let n = min(count, length - position)
        var result: [UInt8] = []
        result.reserveCapacity(n)
        while result.count < n {
            let at = position + result.count
            let block = loadBlock(at / Self.blockSize)
            let index = at % Self.blockSize
            if index >= block.count { break }
            let take = min(n - result.count, block.count - index)
            result.append(contentsOf: block[index..<index + take])
        }
        return result
    }

    private func loadBlock(_ number: Int) -> [UInt8] {
        if let cached = blocks[number] {
            recent.removeAll { $0 == number }
            recent.insert(number, at: 0)
            return cached
        }
        let start = number * Self.blockSize
        let size = max(min(Self.blockSize, length - start), 0)
        var block: [UInt8] = []
        if size > 0, (try? file.seek(toOffset: UInt64(start))) != nil, let data = try? file.read(upToCount: size) {
            block = [UInt8](data)
        }
        blocks[number] = block
        recent.insert(number, at: 0)
        if recent.count > Self.cachedBlocks {
            blocks[recent.removeLast()] = nil
        }
        return block
    }
}

/// A file the reader cannot use: what is wrong, for the message the user sees.
public enum PdfReadProblem: Equatable {
    /// Not a PDF at all (no "%PDF-" header).
    case notPdf
    /// The cross-reference data or an object is not where or what it should be.
    case damaged
    /// The file is encrypted (it has an /Encrypt dictionary).
    case encrypted
    /// The file is encrypted and the password given does not open it.
    case passwordRequired
    /// The file uses something this reader does not handle (a filter other than Flate, say).
    case unsupported
    /// The file is encrypted for recipients and the certificate given, if any, is not one of them or has no private key.
    case certificateRequired
}

/// Thrown by `PdfDocument`; the message is technical, `problem` says what kind.
public struct PdfReadException: Error, CustomStringConvertible {
    public let problem: PdfReadProblem
    public let message: String

    public init(_ problem: PdfReadProblem, _ detail: String) {
        self.problem = problem
        message = detail
    }

    public static func damaged(_ detail: String) -> PdfReadException {
        PdfReadException(.damaged, detail)
    }

    public var description: String { message }
}
