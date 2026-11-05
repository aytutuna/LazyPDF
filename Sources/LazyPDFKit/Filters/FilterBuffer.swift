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
        bytes.append(value)
    }

    func add(_ values: ArraySlice<UInt8>) throws {
        if values.count > max - bytes.count { throw FilterBuffer.tooBig() }
        bytes.append(contentsOf: values)
    }

    func add(_ values: [UInt8]) throws {
        try add(values[...])
    }

    /// Counts `length` more bytes, all `value`.
    func append(_ length: Int, filling value: UInt8) throws {
        if length > max - bytes.count { throw FilterBuffer.tooBig() }
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
}
