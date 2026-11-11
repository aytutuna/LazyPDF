import Foundation

// Twin of windows/LazyPDF.Core/Filters/FilterBuffer.cs: output of a decoder, grows on demand and throws once
// it passes the size cap.

final class FilterBuffer {
    private let max: Int
    private(set) var bytes: [UInt8] = []

    init(_ max: Int, capacity: Int = 0) {
        self.max = max
        bytes.reserveCapacity(Swift.min(Swift.max(capacity, 256), 1 << 22))
    }

    var count: Int { bytes.count }

    static func tooBig() -> PdfReadException {
        PdfReadException(.unsupported, "A stream expands past the size limit.")
    }

    func add(_ value: UInt8) throws {
        if bytes.count >= max { throw FilterBuffer.tooBig() }
        try grow(bytes.count + 1)
        bytes.append(value)
    }

    func add(_ values: ArraySlice<UInt8>) throws {
        if values.count > max - bytes.count { throw FilterBuffer.tooBig() }
        try grow(bytes.count + values.count)
        bytes.append(contentsOf: values)
    }

    func add(_ values: [UInt8]) throws {
        try add(values[...])
    }

    /// Counts `length` more bytes, all `value`.
    func append(_ length: Int, filling value: UInt8) throws {
        if length > max - bytes.count { throw FilterBuffer.tooBig() }
        try grow(bytes.count + length)
        bytes.append(contentsOf: repeatElement(value, count: length))
    }

    /// Counts `length` more bytes and returns where they start, for the caller to fill.
    @discardableResult
    func append(_ length: Int) throws -> Int {
        let start = bytes.count
        try append(length, filling: 0)
        return start
    }

    subscript(index: Int) -> UInt8 {
        get { bytes[index] }
        set { bytes[index] = newValue }
    }

    /// Gives back what was added after the first `count` bytes.
    func truncate(to count: Int) {
        if count < bytes.count { bytes.removeSubrange(count...) }
    }

    func toArray() -> [UInt8] {
        bytes
    }

    // Doubles like the array would, but never past the cap plus one or the largest array the C# side can make.
    private func grow(_ needed: Int) throws {
        if needed > bytes.capacity {
            let size = Swift.min(Swift.max(needed, bytes.capacity * 2), Swift.min(max + 1, FilterBuffer.maxArray))
            if size < needed { throw FilterBuffer.tooBig() }
            bytes.reserveCapacity(size)
        }
    }

    private static let maxArray = 0x7FFF_FFC7
}
