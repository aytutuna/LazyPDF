import Foundation

// Twin of windows/LazyPDF.Core/Office/ZipReader.cs.

/// What a zip package may hold. The ratio applies to entries from `ratioFloor` bytes up, since tiny parts pack oddly.
struct ZipLimits {
    static let ratioFloor = 1 << 20
    static let standard = ZipLimits()

    var maxEntries = 20_000
    var maxTotal = 256 << 20
    var maxEntry = 128 << 20
    var maxRatio = 200
}

/// Reads the entries of a zip file by name, from the central directory (so data descriptors need no care), stored or
/// deflated, zip64 sizes and offsets included. Limits are checked from the sizes the directory declares before anything is
/// inflated, and an entry is inflated no further than its declared size, so a bomb is refused whatever it claims. Part names
/// are case-insensitive, as in OPC packages. Not a validator: bytes outside the entries are ignored.
final class ZipReader {
    private struct Entry {
        let local: Int
        let packed: Int
        let size: Int
        let crc: UInt32
        let method: Int
    }

    private let data: [UInt8]
    private var entries: [String: Entry] = [:]

    /// The names of the files in the package (not folders), in directory order, with / as separator.
    private(set) var names: [String] = []

    private init(_ data: [UInt8]) { self.data = data }

    func contains(_ name: String) -> Bool { entries[ZipReader.key(name)] != nil }

    static func open(_ data: [UInt8], _ limits: ZipLimits = .standard) throws -> ZipReader {
        let zip = ZipReader(data)
        try zip.readDirectory(limits)
        return zip
    }

    func read(_ name: String) throws -> [UInt8] {
        guard let e = entries[ZipReader.key(name)] else { throw PdfReadException.damaged("The package has no part \(name).") }
        let d = data
        if try ZipReader.u32(d, e.local) != 0x04034B50 { throw PdfReadException.damaged("The entry \(name) has no header.") }
        let start = e.local + 30 + (try ZipReader.u16(d, e.local + 26)) + (try ZipReader.u16(d, e.local + 28))
        if start > d.count || e.packed > d.count - start { throw PdfReadException.damaged("The entry \(name) is cut short.") }
        let packed = Array(d[start..<(start + e.packed)])
        let bytes: [UInt8]
        if e.method == 0 {
            if e.packed != e.size { throw PdfReadException.damaged("The entry \(name) has two sizes.") }
            bytes = packed
        } else {
            bytes = e.packed == 0 ? [] : try PdfFilters.inflateRaw(packed, e.size)
        }
        if bytes.count != e.size || ExportZip.crc32(bytes) != e.crc {
            throw PdfReadException.damaged("The entry \(name) does not match its checksum.")
        }
        return bytes
    }

    // OrdinalIgnoreCase upper-cases each UTF-16 unit on its own; a scalar whose upper case is several scalars stays as it is.
    private static func key(_ name: String) -> String {
        var key = String.UnicodeScalarView()
        for s in name.unicodeScalars {
            let upper = s.properties.uppercaseMapping.unicodeScalars
            key.append(upper.count == 1 ? upper.first! : s)
        }
        return String(key)
    }

    private static func cut() -> PdfReadException {
        PdfReadException.damaged("The zip file is cut short or its directory is damaged.")
    }

    private static func over(_ what: String) -> PdfReadException {
        PdfReadException(.unsupported, "The zip file is refused: \(what).")
    }

    private static func u16(_ d: [UInt8], _ at: Int) throws -> Int {
        guard at >= 0, at <= d.count - 2 else { throw cut() }
        return Int(d[at]) | Int(d[at + 1]) << 8
    }

    private static func u32(_ d: [UInt8], _ at: Int) throws -> Int {
        guard at >= 0, at <= d.count - 4 else { throw cut() }
        return Int(d[at]) | Int(d[at + 1]) << 8 | Int(d[at + 2]) << 16 | Int(d[at + 3]) << 24
    }

    private static func u64(_ d: [UInt8], _ at: Int) throws -> Int {
        let low = try u32(d, at), high = try u32(d, at + 4)
        if high >= 1 << 31 { throw cut() }
        return low | high << 32
    }

    private func readDirectory(_ limits: ZipLimits) throws {
        let d = data
        var end = -1
        var i = d.count - 22
        while i >= 0 && i >= d.count - 22 - 0xFFFF {
            if d[i] == 0x50 && d[i + 1] == 0x4B && d[i + 2] == 5 && d[i + 3] == 6 {
                end = i
                break
            }
            i -= 1
        }
        if end < 0 { throw PdfReadException.damaged("There is no zip directory.") }
        if try ZipReader.u16(d, end + 4) != 0 || ZipReader.u16(d, end + 6) != 0 {
            throw PdfReadException(.unsupported, "A zip file in several parts is not supported.")
        }
        var count = try ZipReader.u16(d, end + 10), size = try ZipReader.u32(d, end + 12), offset = try ZipReader.u32(d, end + 16)
        var marked = false
        if end >= 20 { marked = try ZipReader.u32(d, end - 20) == 0x07064B50 }
        if (count == 0xFFFF || size == 0xFFFFFFFF || offset == 0xFFFFFFFF) && marked {
            let record = try ZipReader.u64(d, end - 12)
            if try ZipReader.u32(d, record) != 0x06064B50 { throw ZipReader.cut() }
            count = try ZipReader.u64(d, record + 32)
            size = try ZipReader.u64(d, record + 40)
            offset = try ZipReader.u64(d, record + 48)
        }
        if count > limits.maxEntries { throw ZipReader.over("too many entries") }
        if offset > d.count || size > d.count - offset { throw ZipReader.cut() }

        var at = offset
        var total = 0
        for _ in 0..<count {
            if try ZipReader.u32(d, at) != 0x02014B50 { throw ZipReader.cut() }
            let flags = try ZipReader.u16(d, at + 8), method = try ZipReader.u16(d, at + 10)
            var packed = try ZipReader.u32(d, at + 20), plain = try ZipReader.u32(d, at + 24), local = try ZipReader.u32(d, at + 42)
            let nameLength = try ZipReader.u16(d, at + 28), extraLength = try ZipReader.u16(d, at + 30)
            let commentLength = try ZipReader.u16(d, at + 32)
            let nameAt = at + 46, crc = try ZipReader.u32(d, at + 16)
            let extraAt = nameAt + nameLength
            at = extraAt + extraLength + commentLength
            if at > offset + size { throw ZipReader.cut() }
            if plain == 0xFFFFFFFF || packed == 0xFFFFFFFF || local == 0xFFFFFFFF {
                (plain, packed, local) = try ZipReader.zip64(d, extraAt, extraLength, plain, packed, local)
            }
            if flags & 0x41 != 0 { throw PdfReadException(.unsupported, "An encrypted zip file is not supported.") }

            // Bytes, not Characters: a combining mark after a slash must not hide it.
            let raw = d[nameAt..<(nameAt + nameLength)].map { $0 == 0x5C ? UInt8(0x2F) : $0 }
            let name = String(decoding: raw, as: UTF8.self)
            if raw.first == 0x2F || name.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.count == 2 && $0.allSatisfy { $0 == "." } }) {
                throw PdfReadException.damaged("The entry name \(name) leaves the package.")
            }
            if raw.last == 0x2F { continue }
            if method != 0 && method != 8 {
                throw PdfReadException(.unsupported, "The entry \(name) uses a compression method this reader lacks.")
            }
            if plain > limits.maxEntry { throw ZipReader.over("an entry is too large") }
            if plain >= ZipLimits.ratioFloor {
                let (allowed, overflow) = packed.multipliedReportingOverflow(by: limits.maxRatio)
                if !overflow && plain > allowed { throw ZipReader.over("an entry is packed too tightly") }
            }
            if plain > limits.maxTotal - total { throw ZipReader.over("the entries are too large together") }
            total += plain
            let key = ZipReader.key(name)
            if entries[key] != nil { throw PdfReadException.damaged("The entry \(name) is in the package twice.") }
            entries[key] = Entry(local: local, packed: packed, size: plain, crc: UInt32(truncatingIfNeeded: crc), method: method)
            names.append(name)
        }
    }

    private static func zip64(_ d: [UInt8], _ start: Int, _ length: Int, _ plainIn: Int, _ packedIn: Int,
                              _ localIn: Int) throws -> (Int, Int, Int) {
        var at = start
        var plain = plainIn, packed = packedIn, local = localIn
        let stop = at + length
        while at + 4 <= stop {
            let id = try u16(d, at), field = try u16(d, at + 2)
            at += 4
            if id == 1 {
                if plain == 0xFFFFFFFF { plain = try u64(d, at); at += 8 }
                if packed == 0xFFFFFFFF { packed = try u64(d, at); at += 8 }
                if local == 0xFFFFFFFF { local = try u64(d, at) }
                return (plain, packed, local)
            }
            at += field
        }
        throw cut()
    }
}
