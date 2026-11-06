import Foundation

// No C# twin: what ZipArchive and GZipStream are to PdfRedactor.Verify.cs, as far as the check of an attached file needs
// them. A container that cannot be read here throws `ArchiveError`, which the caller counts as .NET's InvalidDataException:
// the file was not looked into, and the result says so.
//
// Only what ZipArchive reads is read: the central directory (no zip64, no encryption), entries stored or deflated. The sizes
// of the central directory are not trusted for how much is inflated; the budget is. Every member of a gzip file is read, each
// with a trailer (CRC-32 and length) that is its own, and bytes that are no member are unread.

struct ArchiveError: Error {}

enum RedactionArchive {
    struct Entry {
        let method: Int
        let size: Int
        let data: ArraySlice<UInt8>
    }

    private static func u16(_ d: [UInt8], _ at: Int) -> Int? {
        at >= 0 && at + 2 <= d.count ? Int(d[at]) | Int(d[at + 1]) << 8 : nil
    }

    private static func u32(_ d: [UInt8], _ at: Int) -> Int? {
        at >= 0 && at + 4 <= d.count ? Int(d[at]) | Int(d[at + 1]) << 8 | Int(d[at + 2]) << 16 | Int(d[at + 3]) << 24 : nil
    }

    /// The entries of a zip file, in the order of its central directory.
    static func entries(_ d: [UInt8]) throws -> [Entry] {
        // The end record is the last signature in the final 64 KB and its comment.
        var end = -1
        var i = d.count - 22
        let floor = max(0, d.count - 22 - 0xFFFF)
        while i >= floor {
            if d[i] == 0x50 && d[i + 1] == 0x4B && d[i + 2] == 5 && d[i + 3] == 6 {
                end = i
                break
            }
            i -= 1
        }
        guard end >= 0, let total = u16(d, end + 10), let directory = u32(d, end + 16) else { throw ArchiveError() }
        if total == 0xFFFF || directory == 0xFFFF_FFFF { throw ArchiveError() }
        var found: [Entry] = []
        var at = directory
        // ZipArchive reads headers until the signature stops, and refuses a directory that holds another number than the end record says.
        while u32(d, at) == 0x0201_4B50 {
            guard let flags = u16(d, at + 8), let method = u16(d, at + 10), let packed = u32(d, at + 20),
                  let size = u32(d, at + 24), let nameLength = u16(d, at + 28), let extraLength = u16(d, at + 30),
                  let commentLength = u16(d, at + 32), let local = u32(d, at + 42) else { throw ArchiveError() }
            if packed == 0xFFFF_FFFF || size == 0xFFFF_FFFF || flags & 1 != 0 { throw ArchiveError() }
            at += 46 + nameLength + extraLength + commentLength
            guard at <= d.count, u32(d, local) == 0x0403_4B50, let localName = u16(d, local + 26), let localExtra = u16(d, local + 28) else {
                throw ArchiveError()
            }
            let start = local + 30 + localName + localExtra
            guard start + packed <= d.count else { throw ArchiveError() }
            found.append(Entry(method: method, size: size, data: d[start..<start + packed]))
        }
        if found.count != total { throw ArchiveError() }
        return found
    }

    /// The entry inflated; `over` when it holds more than `budget` bytes (what was inflated is then not all of it).
    static func inflate(_ entry: Entry, _ budget: Int) throws -> (bytes: [UInt8], over: Bool) {
        switch entry.method {
        case 0:
            return entry.data.count > budget ? (Array(entry.data.prefix(budget + 1)), true) : (Array(entry.data), false)
        case 8:
            return try raw(Array(entry.data), 0, budget)
        default:
            throw ArchiveError()
        }
    }

    /// Every member of a gzip file inflated and joined, as GZipStream reads them; `over` as above. Bytes that are not a whole
    /// member with a good trailer are unread, since a second member would hide what it holds.
    static func gunzip(_ d: [UInt8], _ budget: Int) throws -> (bytes: [UInt8], over: Bool) {
        var all: [UInt8] = []
        var at = 0
        repeat {
            let member = try gunzipMember(d, at, budget - all.count)
            all += member.bytes
            if member.over { return (all, true) }
            at = member.end
        } while at < d.count
        return (all, false)
    }

    private static func gunzipMember(_ d: [UInt8], _ first: Int, _ budget: Int) throws -> (bytes: [UInt8], over: Bool, end: Int) {
        guard first + 18 <= d.count, d[first] == 0x1F, d[first + 1] == 0x8B, d[first + 2] == 8 else { throw ArchiveError() }
        let flags = d[first + 3]
        var at = first + 10
        if flags & 4 != 0 {
            guard let extra = u16(d, at) else { throw ArchiveError() }
            at += 2 + extra
        }
        for bit: UInt8 in [8, 16] where flags & bit != 0 {
            while at < d.count && d[at] != 0 { at += 1 }
            at += 1
        }
        if flags & 2 != 0 { at += 2 }
        guard at < d.count else { throw ArchiveError() }
        let output = FilterBuffer(budget + 1)
        var end = at
        do {
            if try !Flate.inflate(d, at, output, end: &end) { throw ArchiveError() }
        } catch let error as PdfReadException {
            // The buffer refuses to grow past the budget; that is "more than the budget", not damage.
            if error.message == FilterBuffer.tooBig().message { return (output.toArray(), true, d.count) }
            throw ArchiveError()
        }
        let bytes = output.toArray()
        if bytes.count > budget { return (bytes, true, d.count) }
        guard end + 8 <= d.count, u32(d, end) == Int(crc(bytes)), u32(d, end + 4) == bytes.count & 0xFFFF_FFFF else { throw ArchiveError() }
        return (bytes, false, end + 8)
    }

    private static func raw(_ d: [UInt8], _ start: Int, _ budget: Int) throws -> (bytes: [UInt8], over: Bool) {
        let output = FilterBuffer(budget + 1)
        do {
            if try !Flate.inflate(d, start, output) { throw ArchiveError() }
        } catch let error as PdfReadException {
            // The buffer refuses to grow past the budget; that is "more than the budget", not damage.
            if error.message == FilterBuffer.tooBig().message { return (output.toArray(), true) }
            throw ArchiveError()
        }
        return (output.toArray(), output.count > budget)
    }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
