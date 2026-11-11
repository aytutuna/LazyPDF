import Foundation

// Twin of windows/LazyPDF.Core/Syntax/PdfSyntax.cs: the values (ISO 32000-1 7.3), editable. Strings and
// names keep their bytes, numbers their text, so a dictionary written back says exactly what it said.

private let hexDigits = Array("0123456789ABCDEF".unicodeScalars)

private func appendHex(_ byte: UInt8, to output: inout String) {
    output.unicodeScalars.append(hexDigits[Int(byte >> 4)])
    output.unicodeScalars.append(hexDigits[Int(byte & 15)])
}

/// A PDF value: null, boolean, number, name, string, array, dictionary, reference or stream.
public class PdfObject: CustomStringConvertible {
    init() {}

    /// The value in PDF syntax, as the writer puts it into a file.
    public func writeTo(_ output: inout String) {
        preconditionFailure("Every PdfObject writes itself.")
    }

    public var description: String {
        var text = ""
        writeTo(&text)
        return text
    }
}

public final class PdfNull: PdfObject {
    public static let instance = PdfNull()

    public override func writeTo(_ output: inout String) {
        output.append("null")
    }
}

public final class PdfBoolean: PdfObject {
    public let value: Bool

    public init(_ value: Bool) {
        self.value = value
        super.init()
    }

    public override func writeTo(_ output: inout String) {
        output.append(value ? "true" : "false")
    }
}

/// An integer or a real, kept as it was written ("-.5", "4.", "0012").
public final class PdfNumber: PdfObject {
    public let text: String
    public let value: Double
    public let isInteger: Bool

    public init(_ text: String) {
        self.text = text
        let plain = text.unicodeScalars.allSatisfy { "+-.0123456789eE".unicodeScalars.contains($0) }
        value = plain ? Double(text) ?? 0 : 0
        isInteger = !text.unicodeScalars.contains(".")
        super.init()
    }

    public convenience init(_ value: Int) {
        self.init(String(value))
    }

    /// A real, written with at most six decimals and no exponent.
    public convenience init(_ value: Double) {
        self.init(PdfNumber.format(value))
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = abs(value) < 1e16 ? (value * 1e6).rounded(.toNearestOrEven) / 1e6 : value
        var text = String(format: "%.6f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// The integer value; nil for a real or one out of range.
    public var integer: Int? {
        isInteger ? Int(text) : nil
    }

    public override func writeTo(_ output: inout String) {
        output.append(text)
    }
}

/// A name: its bytes once #xx escapes are undone, one scalar per byte (Latin-1).
public final class PdfName: PdfObject, Hashable {
    public let value: String

    public init(_ value: String) {
        self.value = value
        super.init()
    }

    /// A name for free text: its UTF-8 bytes, one scalar each (7.3.5).
    public static func fromText(_ text: String) -> PdfName {
        PdfName(Latin1.string(Array(text.utf8)))
    }

    /// The text the bytes of `value` spell as UTF-8, or `value` itself when they are not UTF-8.
    public var text: String {
        if value.unicodeScalars.contains(where: { $0.value > 0xFF }) { return value }
        return String(bytes: Latin1.bytes(value), encoding: .utf8) ?? value
    }

    public override func writeTo(_ output: inout String) {
        output.append("/")
        // A scalar above 0xFF has no byte of its own, so its UTF-8 bytes go; then every non-ASCII scalar
        // goes that way, or the mix would not read back as UTF-8.
        let wide = value.unicodeScalars.contains(where: { $0.value > 0xFF })
        for scalar in value.unicodeScalars {
            let c = scalar.value
            // Regular characters as they are; '#', delimiters, white space and anything outside
            // printable ASCII as #xx.
            if c > 0x20 && c < 0x7F && c != 0x23 && !PdfLexer.isDelimiter(Int(c)) {
                output.unicodeScalars.append(scalar)
            } else if c <= 0xFF && !(wide && c > 0x7F) {
                output.append("#")
                appendHex(UInt8(c), to: &output)
            } else {
                for byte in String(scalar).utf8 {
                    output.append("#")
                    appendHex(byte, to: &output)
                }
            }
        }
    }

    public static func == (a: PdfName, b: PdfName) -> Bool {
        a.value == b.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }
}

/// A string's bytes, and whether it was written in hex.
public final class PdfString: PdfObject {
    public var bytes: [UInt8]
    public var isHex: Bool

    public init(bytes: [UInt8], isHex: Bool) {
        self.bytes = bytes
        self.isHex = isHex
        super.init()
    }

    public override func writeTo(_ output: inout String) {
        if isHex {
            output.append("<")
            for byte in bytes { appendHex(byte, to: &output) }
            output.append(">")
            return
        }
        output.append("(")
        for b in bytes {
            switch b {
            case 0x5C: output.append("\\\\")
            case 0x28: output.append("\\(")
            case 0x29: output.append("\\)")
            // A bare CR in a literal string reads back as LF: escape it to keep the byte.
            case 0x0D: output.append("\\r")
            case 0x0A: output.append("\\n")
            default:
                if b < 0x20 || b >= 0x7F {
                    output.append("\\")
                    for shift in [6, 3, 0] {
                        output.unicodeScalars.append(hexDigits[Int((b >> UInt8(shift)) & 7)])
                    }
                } else {
                    output.unicodeScalars.append(Unicode.Scalar(b))
                }
            }
        }
        output.append(")")
    }
}

public final class PdfArray: PdfObject {
    public var items: [PdfObject]

    public init(_ items: [PdfObject]) {
        self.items = items
        super.init()
    }

    public override func writeTo(_ output: inout String) {
        output.append("[")
        for (i, item) in items.enumerated() {
            if i > 0 { output.append(" ") }
            item.writeTo(&output)
        }
        output.append("]")
    }
}

/// A dictionary, its entries in the order they were written (a repeated key: the last one counts).
public final class PdfDictionary: PdfObject {
    // Past this many entries a lookup goes through an index instead of a scan.
    private static let indexFrom = 12

    private var storage: [(key: String, value: PdfObject)] = []
    private var last: [String: Int]?

    public override init() {
        super.init()
    }

    public var entries: [(key: String, value: PdfObject)] { storage }

    public var count: Int { storage.count }

    public subscript(key: String) -> PdfObject? {
        get {
            let index = lastIndexOf(key)
            return index >= 0 ? storage[index].value : nil
        }
        set {
            guard let value = newValue else {
                remove(key)
                return
            }
            let index = lastIndexOf(key)
            if index >= 0 {
                storage[index] = (key, value)
            } else {
                add(key, value)
            }
        }
    }

    public func containsKey(_ key: String) -> Bool {
        lastIndexOf(key) >= 0
    }

    public func add(_ key: String, _ value: PdfObject) {
        storage.append((key, value))
        last?[key] = storage.count - 1
    }

    /// Removes every entry with `key`; false when there was none.
    @discardableResult
    public func remove(_ key: String) -> Bool {
        let before = storage.count
        storage.removeAll { $0.key == key }
        if storage.count == before { return false }
        last = nil
        return true
    }

    private func lastIndexOf(_ key: String) -> Int {
        if storage.count < Self.indexFrom {
            for i in stride(from: storage.count - 1, through: 0, by: -1) where storage[i].key == key {
                return i
            }
            return -1
        }
        if last == nil {
            var index: [String: Int] = Dictionary(minimumCapacity: storage.count)
            for (i, entry) in storage.enumerated() { index[entry.key] = i }
            last = index
        }
        return last?[key] ?? -1
    }

    /// A copy whose entries can be changed without changing this one (the values are shared).
    public func copy() -> PdfDictionary {
        let copy = PdfDictionary()
        copy.storage = storage
        return copy
    }

    public override func writeTo(_ output: inout String) {
        output.append("<<")
        var first = true
        for (i, entry) in storage.enumerated() {
            // The last of repeated keys only, where it was written.
            if lastIndexOf(entry.key) != i { continue }
            if !first { output.append(" ") }
            first = false
            PdfName(entry.key).writeTo(&output)
            output.append(" ")
            entry.value.writeTo(&output)
        }
        output.append(">>")
    }
}

/// An indirect reference, "12 0 R".
public final class PdfReference: PdfObject, Hashable {
    public let number: Int
    public let generation: Int

    public init(_ number: Int, _ generation: Int) {
        self.number = number
        self.generation = generation
        super.init()
    }

    public override func writeTo(_ output: inout String) {
        output.append("\(number) \(generation) R")
    }

    public static func == (a: PdfReference, b: PdfReference) -> Bool {
        a.number == b.number && a.generation == b.generation
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(number)
        hasher.combine(generation)
    }
}

/// A stream: its dictionary, and its data either where it starts in the bytes it was read from or
/// in memory. The length may be an indirect object, so the document works the data out
/// (`PdfDocument.rawData`).
public final class PdfStream: PdfObject {
    public let dictionary: PdfDictionary

    /// Where the data starts in the file read; -1 for a stream made in memory.
    public let dataOffset: Int

    /// The data as it is to be stored, filters applied, not encrypted. Nil for a stream read from
    /// a file whose data is still there; setting it replaces the data and marks the stream changed.
    public var data: [UInt8]?

    /// The object number and generation of the stream, set where it becomes an indirect object.
    public internal(set) var number = 0
    public internal(set) var generation = 0

    public init(_ dictionary: PdfDictionary, dataOffset: Int) {
        self.dictionary = dictionary
        self.dataOffset = dataOffset
        super.init()
    }

    public convenience init(_ dictionary: PdfDictionary, data: [UInt8]) {
        self.init(dictionary, dataOffset: -1)
        self.data = data
    }

    /// Streams are never written back (an update only adds new ones).
    public override func writeTo(_ output: inout String) {
        preconditionFailure("A stream is written only as an indirect object.")
    }

    public override var description: String { "stream \(number) \(generation)" }
}
