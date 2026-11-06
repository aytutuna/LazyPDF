import Foundation

// No C# twin: System.Formats.Asn1 (AsnReader, AsnWriter) reads and writes the CMS, certificates, OCSP responses and
// lists in the C#. This is the small part of it the signature code uses: a BER reader that throws AsnContentException
// for what does not read, and DER writers (ITU-T X.690). Definite and indefinite lengths are read, to a depth of
// maxDepth; high tag numbers are not.

struct AsnContentException: Error {}

struct AsnTag: Equatable {
    var tagClass: UInt8
    var isConstructed: Bool
    var value: Int

    /// 0 universal, 1 application, 2 context-specific, 3 private.
    static let sequence = AsnTag(tagClass: 0, isConstructed: true, value: 16)
    static let set = AsnTag(tagClass: 0, isConstructed: true, value: 17)

    static func context(_ value: Int, constructed: Bool = false) -> AsnTag {
        AsnTag(tagClass: 2, isConstructed: constructed, value: value)
    }

    func hasSameClassAndValue(_ other: AsnTag) -> Bool {
        tagClass == other.tagClass && value == other.value
    }
}

enum AsnUniversal {
    static let boolean = 1
    static let integer = 2
    static let bitString = 3
    static let octetString = 4
    static let null = 5
    static let objectIdentifier = 6
    static let enumerated = 10
    static let sequence = 16
    static let set = 17
    static let utcTime = 23
    static let generalizedTime = 24
}

/// An INTEGER as a sign and a magnitude without leading zeros (BigInteger in the C#).
struct AsnInteger: Hashable {
    var negative: Bool
    var magnitude: [UInt8]

    init(negative: Bool = false, magnitude: [UInt8]) {
        var trimmed = magnitude[...]
        while trimmed.first == 0 { trimmed = trimmed.dropFirst() }
        self.magnitude = Array(trimmed)
        self.negative = negative && !trimmed.isEmpty
    }

    /// Big-endian unsigned bytes.
    init(unsigned bytes: [UInt8]) {
        self.init(negative: false, magnitude: bytes)
    }

    init(_ value: Int) {
        var bytes: [UInt8] = []
        var rest = value.magnitude
        while rest > 0 {
            bytes.insert(UInt8(truncatingIfNeeded: rest), at: 0)
            rest >>= 8
        }
        self.init(negative: value < 0, magnitude: bytes)
    }

    /// The content bytes of a DER INTEGER: two's complement, big-endian.
    init(derContent content: [UInt8]) throws {
        guard let first = content.first else { throw AsnContentException() }
        if first & 0x80 == 0 {
            self.init(negative: false, magnitude: content)
            return
        }
        // Negative: invert and add one.
        var inverted = content.map { ~$0 }
        var i = inverted.count - 1
        while i >= 0 {
            if inverted[i] == 0xFF {
                inverted[i] = 0
                i -= 1
            } else {
                inverted[i] += 1
                break
            }
        }
        if i < 0 { inverted.insert(1, at: 0) }
        self.init(negative: true, magnitude: inverted)
    }

    /// The value when it fits an Int.
    var intValue: Int? {
        if magnitude.count > 8 { return nil }
        var value: UInt64 = 0
        for byte in magnitude { value = value << 8 | UInt64(byte) }
        if negative { return value <= UInt64(Int.max) + 1 ? Int(truncatingIfNeeded: 0 &- value) : nil }
        return value <= UInt64(Int.max) ? Int(value) : nil
    }

    /// The content bytes of a DER INTEGER.
    var derContent: [UInt8] {
        if magnitude.isEmpty { return [0] }
        if !negative { return (magnitude[0] & 0x80 != 0 ? [0] : []) + magnitude }
        // Two's complement of the magnitude.
        var bytes = magnitude.map { ~$0 }
        var i = bytes.count - 1
        while i >= 0 {
            if bytes[i] == 0xFF {
                bytes[i] = 0
                i -= 1
            } else {
                bytes[i] += 1
                break
            }
        }
        if bytes[0] & 0x80 == 0 { bytes.insert(0xFF, at: 0) }
        return bytes
    }
}

struct AsnReader {
    static let maxDepth = 32

    private let data: [UInt8]
    private var position: Int
    private let end: Int

    init(_ data: [UInt8]) {
        self.data = data
        position = 0
        end = data.count
    }

    private init(_ data: [UInt8], _ start: Int, _ end: Int) {
        self.data = data
        position = start
        self.end = end
    }

    var hasData: Bool { position < end }

    private struct Header {
        var tag: AsnTag
        var contentStart: Int
        /// Nil for an indefinite length.
        var length: Int?
    }

    private func header(at start: Int) throws -> Header {
        guard start >= 0, start + 2 <= end else { throw AsnContentException() }
        let first = data[start]
        if first & 0x1F == 0x1F { throw AsnContentException() }
        let tag = AsnTag(tagClass: first >> 6, isConstructed: first & 0x20 != 0, value: Int(first & 0x1F))
        let lengthByte = data[start + 1]
        var at = start + 2
        if lengthByte < 0x80 {
            guard Int(lengthByte) <= end - at else { throw AsnContentException() }
            return Header(tag: tag, contentStart: at, length: Int(lengthByte))
        }
        if lengthByte == 0x80 {
            guard tag.isConstructed else { throw AsnContentException() }
            return Header(tag: tag, contentStart: at, length: nil)
        }
        let count = Int(lengthByte & 0x7F)
        guard count <= 4, at + count <= end else { throw AsnContentException() }
        var length = 0
        for i in 0..<count { length = length << 8 | Int(data[at + i]) }
        at += count
        guard length <= end - at else { throw AsnContentException() }
        return Header(tag: tag, contentStart: at, length: length)
    }

    /// Where the value that starts at `start` ends, past its end-of-contents pair when the length is indefinite.
    private func valueEnd(_ start: Int, _ depth: Int) throws -> Int {
        guard depth <= Self.maxDepth else { throw AsnContentException() }
        let h = try header(at: start)
        if let length = h.length { return h.contentStart + length }
        var at = h.contentStart
        while true {
            guard at + 2 <= end else { throw AsnContentException() }
            if data[at] == 0 && data[at + 1] == 0 { return at + 2 }
            at = try valueEnd(at, depth + 1)
        }
    }

    /// The content of the value at `start`, without the end-of-contents pair.
    private func contentRange(_ start: Int) throws -> Range<Int> {
        let h = try header(at: start)
        let after = try valueEnd(start, 0)
        return h.contentStart..<(h.length == nil ? after - 2 : after)
    }

    func peekTag() throws -> AsnTag {
        try header(at: position).tag
    }

    func peekEncodedValue() throws -> [UInt8] {
        let stop = try valueEnd(position, 0)
        return Array(data[position..<stop])
    }

    mutating func readEncodedValue() throws -> [UInt8] {
        let value = try peekEncodedValue()
        position += value.count
        return value
    }

    private mutating func readConstructed(_ expected: AsnTag) throws -> AsnReader {
        let h = try header(at: position)
        guard h.tag.hasSameClassAndValue(expected), h.tag.isConstructed else { throw AsnContentException() }
        let range = try contentRange(position)
        position = try valueEnd(position, 0)
        return AsnReader(data, range.lowerBound, range.upperBound)
    }

    mutating func readSequence(_ tag: AsnTag = .sequence) throws -> AsnReader {
        try readConstructed(tag)
    }

    mutating func readSetOf(_ tag: AsnTag = .set) throws -> AsnReader {
        try readConstructed(tag)
    }

    private mutating func readPrimitive(_ expected: AsnTag) throws -> [UInt8] {
        let h = try header(at: position)
        guard h.tag.hasSameClassAndValue(expected), !h.tag.isConstructed, let length = h.length else { throw AsnContentException() }
        position = h.contentStart + length
        return Array(data[h.contentStart..<h.contentStart + length])
    }

    mutating func readInteger() throws -> AsnInteger {
        let content = try readPrimitive(AsnTag(tagClass: 0, isConstructed: false, value: AsnUniversal.integer))
        return try AsnInteger(derContent: content)
    }

    /// A small INTEGER; throws for one that does not fit.
    mutating func readInt() throws -> Int {
        guard let value = try readInteger().intValue else { throw AsnContentException() }
        return value
    }

    mutating func readBoolean(_ tag: AsnTag = AsnTag(tagClass: 0, isConstructed: false, value: AsnUniversal.boolean)) throws -> Bool {
        let content = try readPrimitive(tag)
        guard content.count == 1 else { throw AsnContentException() }
        return content[0] != 0
    }

    mutating func readNull() throws {
        let content = try readPrimitive(AsnTag(tagClass: 0, isConstructed: false, value: AsnUniversal.null))
        guard content.isEmpty else { throw AsnContentException() }
    }

    mutating func readEnumeratedBytes() throws -> [UInt8] {
        let content = try readPrimitive(AsnTag(tagClass: 0, isConstructed: false, value: AsnUniversal.enumerated))
        guard !content.isEmpty else { throw AsnContentException() }
        return content
    }

    mutating func readObjectIdentifier() throws -> String {
        let content = try readPrimitive(AsnTag(tagClass: 0, isConstructed: false, value: AsnUniversal.objectIdentifier))
        guard !content.isEmpty else { throw AsnContentException() }
        var arcs: [Int] = []
        var value = 0
        var open = false
        for byte in content {
            if value > Int.max >> 8 { throw AsnContentException() }
            value = value << 7 | Int(byte & 0x7F)
            open = byte & 0x80 != 0
            if !open {
                arcs.append(value)
                value = 0
            }
        }
        guard !open, let first = arcs.first else { throw AsnContentException() }
        let head = first < 40 ? [0, first] : first < 80 ? [1, first - 40] : [2, first - 80]
        return (head + arcs.dropFirst()).map { String($0) }.joined(separator: ".")
    }

    /// An OCTET STRING of the tag, primitive or (BER) in pieces.
    mutating func readOctetString(_ tag: AsnTag = AsnTag(tagClass: 0, isConstructed: false, value: AsnUniversal.octetString)) throws -> [UInt8] {
        let h = try header(at: position)
        guard h.tag.hasSameClassAndValue(tag) else { throw AsnContentException() }
        let result = try octets(position, 0)
        position = try valueEnd(position, 0)
        return result
    }

    private func octets(_ start: Int, _ depth: Int) throws -> [UInt8] {
        guard depth <= Self.maxDepth else { throw AsnContentException() }
        let h = try header(at: start)
        if !h.tag.isConstructed {
            guard let length = h.length else { throw AsnContentException() }
            return Array(data[h.contentStart..<h.contentStart + length])
        }
        let range = try contentRange(start)
        var joined: [UInt8] = []
        var at = range.lowerBound
        while at < range.upperBound {
            let piece = try header(at: at)
            guard piece.tag.tagClass == 0, piece.tag.value == AsnUniversal.octetString else { throw AsnContentException() }
            joined += try octets(at, depth + 1)
            at = try valueEnd(at, 0)
        }
        return joined
    }

    /// The bits of a BIT STRING as bytes (the count of unused bits must be 0 to 7).
    mutating func readBitString() throws -> [UInt8] {
        let content = try readPrimitive(AsnTag(tagClass: 0, isConstructed: false, value: AsnUniversal.bitString))
        guard let unused = content.first, unused <= 7, unused == 0 || content.count > 1 else { throw AsnContentException() }
        return Array(content.dropFirst())
    }

    mutating func readUtcTime() throws -> DateTimeOffset {
        let text = try readPrimitive(AsnTag(tagClass: 0, isConstructed: false, value: AsnUniversal.utcTime))
        return try Self.time(text, century: false)
    }

    mutating func readGeneralizedTime() throws -> DateTimeOffset {
        let text = try readPrimitive(AsnTag(tagClass: 0, isConstructed: false, value: AsnUniversal.generalizedTime))
        return try Self.time(text, century: true)
    }

    // YYMMDDhhmm[ss](Z|+hhmm|-hhmm), or YYYYMMDDhh[mm[ss[.f]]] with the same endings. A two-digit year up to 49 is 20yy.
    private static func time(_ text: [UInt8], century: Bool) throws -> DateTimeOffset {
        var at = 0
        func digits(_ count: Int) throws -> Int {
            guard at + count <= text.count else { throw AsnContentException() }
            var value = 0
            for i in 0..<count {
                let c = text[at + i]
                guard c >= 0x30, c <= 0x39 else { throw AsnContentException() }
                value = value * 10 + Int(c - 0x30)
            }
            at += count
            return value
        }
        var year = try digits(century ? 4 : 2)
        if !century { year += year <= 49 ? 2000 : 1900 }
        let month = try digits(2), day = try digits(2), hour = try digits(2)
        var minute = 0, second = 0, ticks = 0
        if century {
            if at < text.count, text[at] >= 0x30, text[at] <= 0x39 { minute = try digits(2) }
            if at < text.count, text[at] >= 0x30, text[at] <= 0x39 { second = try digits(2) }
            if at < text.count, text[at] == UInt8(ascii: ".") || text[at] == UInt8(ascii: ",") {
                at += 1
                var scale = 1_000_000
                var any = false
                while at < text.count, text[at] >= 0x30, text[at] <= 0x39 {
                    ticks += Int(text[at] - 0x30) * scale
                    scale /= 10
                    at += 1
                    any = true
                }
                if !any { throw AsnContentException() }
                ticks = min(ticks, 9_999_999)
            }
        } else {
            minute = try digits(2)
            if at < text.count, text[at] >= 0x30, text[at] <= 0x39 { second = try digits(2) }
        }
        var offset = 0
        guard at < text.count else { throw AsnContentException() }
        if text[at] == UInt8(ascii: "Z") {
            at += 1
        } else if text[at] == UInt8(ascii: "+") || text[at] == UInt8(ascii: "-") {
            let sign = text[at] == UInt8(ascii: "-") ? -1 : 1
            at += 1
            let h = try digits(2), m = try digits(2)
            offset = sign * (h * 60 + m)
        } else {
            throw AsnContentException()
        }
        guard at == text.count, let time = DateTimeOffset(valid: year, month, day, hour, minute, second, ticks: ticks, offsetMinutes: offset) else {
            throw AsnContentException()
        }
        return time
    }
}

extension DerWriter {
    private static func sortedSet(_ tag: UInt8, _ items: [[UInt8]]) -> [UInt8] {
        let sorted = items.sorted { $0.lexicographicallyPrecedes($1) }
        return node(tag, sorted.flatMap { $0 })
    }

    /// SET OF in DER: the encodings in ascending order.
    static func setOf(_ items: [[UInt8]], tag: UInt8 = 0x31) -> [UInt8] {
        sortedSet(tag, items)
    }

    static func integer(_ value: AsnInteger) -> [UInt8] {
        node(0x02, value.derContent)
    }

    static func integer(unsigned bytes: [UInt8]) -> [UInt8] {
        integer(AsnInteger(unsigned: bytes))
    }

    static func boolean(_ value: Bool) -> [UInt8] {
        node(0x01, [value ? 0xFF : 0])
    }

    static func bitString(_ bytes: [UInt8]) -> [UInt8] {
        node(0x03, [0] + bytes)
    }

    static func enumerated(_ value: UInt8) -> [UInt8] {
        node(0x0A, [value])
    }

    static func ia5String(_ text: String, tag: UInt8 = 0x16) -> [UInt8] {
        node(tag, Array(text.utf8))
    }

    /// UTCTime for 1950 to 2049, GeneralizedTime otherwise; seconds are kept, fractions are not.
    static func time(_ date: DateTimeOffset) -> [UInt8] {
        let utc = date.utc
        if utc.year >= 1950 && utc.year <= 2049 { return utcTime(date) }
        return generalizedTime(date)
    }

    static func utcTime(_ date: DateTimeOffset) -> [UInt8] {
        let u = date.utc
        return node(0x17, Array(String(format: "%02ld%02ld%02ld%02ld%02ld%02ldZ", u.year % 100, u.month, u.day, u.hour, u.minute, u.second).utf8))
    }

    static func generalizedTime(_ date: DateTimeOffset) -> [UInt8] {
        let u = date.utc
        return node(0x18, Array(String(format: "%04ld%02ld%02ld%02ld%02ld%02ldZ", u.year, u.month, u.day, u.hour, u.minute, u.second).utf8))
    }

    /// A value with an explicit or implicit context tag number.
    static func context(_ number: Int, constructed: Bool, _ content: [UInt8]) -> [UInt8] {
        node(UInt8(0x80 | (constructed ? 0x20 : 0) | number), content)
    }
}
