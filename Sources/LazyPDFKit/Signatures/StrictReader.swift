import Foundation

// Twin of windows/LazyPDF.Core/Signatures/StrictReader.cs: reads the syntax of ISO 32000-1 7.3 as written and nothing
// else: no comments, no signs inside numbers, no keys twice in a dictionary, no unknown escapes or keywords. Where
// PdfLexer repairs, this stops, so the bytes that pass mean the same to every reader. It never throws; a method that
// returns false or nil leaves `pos` where it gave up.

struct Slice: Equatable {
    var start: Int
    var end: Int
}

final class StrictReader {
    private static let maxDepth = 64
    private static let maxNumber = PdfDocument.maxObjectNumber

    private let data: [UInt8]
    private let end: Int

    var pos = 0

    /// Set when reading the signed revision, which is a conforming file rather than an update to be placed exactly: a
    /// stream's /Length may be a reference, this finds the number it holds, and a backslash before a character that
    /// needs none is ignored (7.3.4.2).
    var lengths: ((Int) -> Int?)?

    init(_ data: [UInt8], _ end: Int) {
        self.data = data
        self.end = end
    }

    var atEnd: Bool { pos >= end }

    /// An indirect object: its place, and for a dictionary the span of each top-level value.
    struct Indirect {
        var number: Int
        var generation: Int
        var start: Int
        var end: Int
        var keys: [String: Slice]?
        var isStream: Bool
    }

    static func isSpace(_ b: UInt8) -> Bool { b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32 }

    private static func isDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "["), UInt8(ascii: "]"),
             UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "/"), UInt8(ascii: "%"):
            return true
        default:
            return false
        }
    }

    func skipSpace() {
        while pos < end && Self.isSpace(data[pos]) { pos += 1 }
    }

    private func atBoundary(_ at: Int) -> Bool {
        at >= end || Self.isSpace(data[at]) || Self.isDelimiter(data[at])
    }

    /// The keyword at `pos`, which must stand alone: followed by white space, a delimiter or the end.
    func word(_ word: String) -> Bool {
        let bytes = Array(word.utf8)
        if end - pos < bytes.count || Array(data[pos..<pos + bytes.count]) != bytes || !atBoundary(pos + bytes.count) { return false }
        pos += bytes.count
        return true
    }

    /// Plain digits, at most 18, standing alone.
    func unsigned() -> Int? {
        var value = 0
        var at = pos
        while at < end && data[at] >= UInt8(ascii: "0") && data[at] <= UInt8(ascii: "9") {
            if at - pos >= 18 { return nil }
            value = value * 10 + Int(data[at] - UInt8(ascii: "0"))
            at += 1
        }
        if at == pos || !atBoundary(at) { return nil }
        pos = at
        return value
    }

    /// The span of the value at `pos`, after any white space; ok is false when there is none or it is malformed.
    func value(depth: Int = 0, keys: KeySpans? = nil) -> (ok: Bool, slice: Slice) {
        skipSpace()
        let start = pos
        let ok = readValue(depth, keys)
        return (ok, Slice(start: start, end: pos))
    }

    /// A dictionary the top-level values of a dictionary are noted in.
    final class KeySpans {
        var map: [String: Slice] = [:]
    }

    private func readValue(_ depth: Int, _ keys: KeySpans?) -> Bool {
        if depth > Self.maxDepth || pos >= end { return false }
        switch data[pos] {
        case UInt8(ascii: "/"): return name() != nil
        case UInt8(ascii: "("): return literalString()
        case UInt8(ascii: "<"): return pos + 1 < end && data[pos + 1] == UInt8(ascii: "<") ? readDictionary(depth, keys) : hexString()
        case UInt8(ascii: "["): return readArray(depth)
        case UInt8(ascii: "t"): return word("true")
        case UInt8(ascii: "f"): return word("false")
        case UInt8(ascii: "n"): return word("null")
        default: return number()
        }
    }

    func name() -> String? {
        var text = String.UnicodeScalarView()
        var at = pos + 1
        while at < end && !Self.isSpace(data[at]) && !Self.isDelimiter(data[at]) {
            let b = data[at]
            if b == UInt8(ascii: "#") {
                if at + 2 >= end { return nil }
                let high = Self.hex(data[at + 1]), low = Self.hex(data[at + 2])
                if high < 0 || low < 0 || (high | low) == 0 { return nil }
                text.append(Unicode.Scalar(UInt8(high << 4 | low)))
                at += 3
            } else if b < 0x21 || b > 0x7E {
                return nil
            } else {
                text.append(Unicode.Scalar(b))
                at += 1
            }
        }
        pos = at
        return String(text)
    }

    private static func hex(_ c: UInt8) -> Int {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(c - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(c - UInt8(ascii: "A")) + 10
        default: return -1
        }
    }

    // A sign, digits and one point (7.3.3); "N G R" is a reference when both numbers are plain and in range.
    private func number() -> Bool {
        var at = pos
        let signed = data[at] == UInt8(ascii: "+") || data[at] == UInt8(ascii: "-")
        if signed { at += 1 }
        var digits = 0, points = 0
        while at < end && ((data[at] >= UInt8(ascii: "0") && data[at] <= UInt8(ascii: "9")) || data[at] == UInt8(ascii: ".")) {
            if data[at] == UInt8(ascii: ".") { points += 1 } else { digits += 1 }
            at += 1
        }
        if digits == 0 || points > 1 || !atBoundary(at) { return false }
        if signed || points > 0 || digits > 7 {
            pos = at
            return true
        }
        let number = unsigned() ?? 0
        let back = pos
        if pos < end && Self.isSpace(data[pos]) {
            skipSpace()
            if let generation = unsigned(), pos < end, Self.isSpace(data[pos]) {
                skipSpace()
                if word("R") { return number >= 1 && number <= Self.maxNumber && generation <= 65535 }
            }
        }
        pos = back
        return true
    }

    private func literalString() -> Bool {
        var depth = 0
        var at = pos
        while at < end {
            let b = data[at]
            if b == UInt8(ascii: "\\") {
                at += 1
                if at >= end { return false }
                let next = data[at]
                if next >= UInt8(ascii: "0") && next <= UInt8(ascii: "7") {
                    var n = 1
                    while n < 3 && at + 1 < end && data[at + 1] >= UInt8(ascii: "0") && data[at + 1] <= UInt8(ascii: "7") {
                        at += 1
                        n += 1
                    }
                } else if next == UInt8(ascii: "\r") {
                    if at + 1 < end && data[at + 1] == UInt8(ascii: "\n") { at += 1 }
                } else if lengths == nil && !Self.escapes.contains(next) {
                    return false
                }
            } else if b == UInt8(ascii: "(") {
                depth += 1
            } else if b == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 {
                    pos = at + 1
                    return true
                }
            }
            at += 1
        }
        return false
    }

    private static let escapes: Set<UInt8> = [UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"), UInt8(ascii: "b"), UInt8(ascii: "f"),
                                              UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"), UInt8(ascii: "\n")]

    private func hexString() -> Bool {
        var at = pos + 1
        while at < end {
            if data[at] == UInt8(ascii: ">") {
                pos = at + 1
                return true
            }
            if !Self.isSpace(data[at]) && Self.hex(data[at]) < 0 { return false }
            at += 1
        }
        return false
    }

    private func readArray(_ depth: Int) -> Bool {
        pos += 1
        while true {
            skipSpace()
            if pos < end && data[pos] == UInt8(ascii: "]") {
                pos += 1
                return true
            }
            if !readValue(depth + 1, nil) { return false }
        }
    }

    private func readDictionary(_ depth: Int, _ keys: KeySpans?) -> Bool {
        pos += 2
        var names = Set<String>()
        while true {
            skipSpace()
            if pos + 1 < end && data[pos] == UInt8(ascii: ">") && data[pos + 1] == UInt8(ascii: ">") {
                pos += 2
                return true
            }
            if pos >= end || data[pos] != UInt8(ascii: "/") { return false }
            guard let key = name(), names.insert(key).inserted else { return false }
            skipSpace()
            let start = pos
            if !readValue(depth + 1, nil) { return false }
            keys?.map[key] = Slice(start: start, end: pos)
        }
    }

    /// "N G obj", the object, and "endobj" (7.3.10). A stream's data is exactly /Length bytes, a direct integer (7.3.8.2).
    func object() -> Indirect? {
        skipSpace()
        let start = pos
        guard let number = unsigned(), number >= 1, number <= Self.maxNumber else { return nil }
        skipSpace()
        guard let generation = unsigned(), generation <= 65535 else { return nil }
        skipSpace()
        if !word("obj") { return nil }
        skipSpace()
        let keys: KeySpans? = pos < end && data[pos] == UInt8(ascii: "<") && pos + 1 < end && data[pos + 1] == UInt8(ascii: "<") ? KeySpans() : nil
        if !value(depth: 0, keys: keys).ok { return nil }
        skipSpace()
        let stream = keys != nil && word("stream")
        if stream, let keys, !streamData(keys.map) { return nil }
        skipSpace()
        if !word("endobj") { return nil }
        return Indirect(number: number, generation: generation, start: start, end: pos, keys: keys?.map, isStream: stream)
    }

    private func streamData(_ keys: [String: Slice]) -> Bool {
        if pos < end && data[pos] == UInt8(ascii: "\r") && pos + 1 < end && data[pos + 1] == UInt8(ascii: "\n") {
            pos += 2
        } else if pos < end && data[pos] == UInt8(ascii: "\n") {
            pos += 1
        } else {
            return false
        }
        guard let slice = keys["Length"], let length = lengthOf(slice), length <= end - pos else { return false }
        pos += length
        if pos < end && data[pos] == UInt8(ascii: "\r") {
            pos += 1
            if pos < end && data[pos] == UInt8(ascii: "\n") { pos += 1 }
        } else if pos < end && data[pos] == UInt8(ascii: "\n") {
            pos += 1
        }
        return word("endstream")
    }

    private func lengthOf(_ slice: Slice) -> Int? {
        if let length = integer(slice) { return length }
        if let lengths, let number = reference(slice), let found = lengths(number), found >= 0 { return found }
        return nil
    }

    /// The span holds nothing but a reference.
    func reference(_ slice: Slice) -> Int? {
        let reader = StrictReader(data, slice.end)
        reader.pos = slice.start
        guard let n = reader.unsigned() else { return nil }
        reader.skipSpace()
        guard let generation = reader.unsigned() else { return nil }
        reader.skipSpace()
        if !reader.word("R") || reader.pos != slice.end || n < 1 || n > Self.maxNumber || generation > 65535 { return nil }
        return n
    }

    /// The span holds nothing but a plain unsigned integer.
    func integer(_ slice: Slice) -> Int? {
        let reader = StrictReader(data, slice.end)
        reader.pos = slice.start
        guard let value = reader.unsigned(), reader.pos == slice.end else { return nil }
        return value
    }

    /// The span holds nothing but a name.
    func nameOf(_ slice: Slice) -> String? {
        let reader = StrictReader(data, slice.end)
        reader.pos = slice.start
        guard slice.start < slice.end, data[slice.start] == UInt8(ascii: "/"), let name = reader.name(), reader.pos == slice.end else { return nil }
        return name
    }

    /// The span holds nothing but an array of plain unsigned integers.
    func integers(_ slice: Slice) -> [Int]? {
        let reader = StrictReader(data, slice.end)
        reader.pos = slice.start
        if slice.start >= slice.end || data[slice.start] != UInt8(ascii: "[") { return nil }
        reader.pos += 1
        var values: [Int] = []
        while true {
            reader.skipSpace()
            if reader.pos < slice.end && data[reader.pos] == UInt8(ascii: "]") { return reader.pos + 1 == slice.end ? values : nil }
            guard let value = reader.unsigned() else { return nil }
            values.append(value)
        }
    }

    /// The span holds nothing but an array of two values.
    func pair(_ slice: Slice) -> (first: Slice, second: Slice)? {
        let reader = StrictReader(data, slice.end)
        reader.pos = slice.start
        if slice.start >= slice.end || data[slice.start] != UInt8(ascii: "[") { return nil }
        reader.pos += 1
        let first = reader.value(), second = reader.value()
        if !first.ok || !second.ok { return nil }
        reader.skipSpace()
        return reader.pos + 1 == slice.end && data[reader.pos] == UInt8(ascii: "]") ? (first.slice, second.slice) : nil
    }

    func same(_ a: Slice, _ b: Slice) -> Bool {
        data[a.start..<a.end] == data[b.start..<b.end]
    }
}
