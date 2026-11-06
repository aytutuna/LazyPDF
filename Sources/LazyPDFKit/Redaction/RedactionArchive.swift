import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionArchive.cs: reads a zip or gzip file the way the check of an attached file
// needs, strictly, so that a file counts as read only when every byte of it is accounted for. A file that cannot be accounted
// for is nil, and the caller counts it as not checked. The C# inflates with DeflateStream and learns what it used through a
// stream that gives one byte at a time; here the inflater says where its last block ended.

enum RedactionArchive {
    /// Whether the data holds the signature of a local header or of an end record, wherever it is.
    static func hasZipSignature(_ d: [UInt8]) -> Bool {
        d.indexOf([0x50, 0x4B, 3, 4]) != nil || d.indexOf([0x50, 0x4B, 5, 6]) != nil
    }

    private static func u16(_ d: [UInt8], _ at: Int) -> Int {
        at >= 0 && at + 2 <= d.count ? Int(d[at]) | Int(d[at + 1]) << 8 : -1
    }

    private static func u32(_ d: [UInt8], _ at: Int) -> Int {
        at >= 0 && at + 4 <= d.count ? Int(d[at]) | Int(d[at + 1]) << 8 | Int(d[at + 2]) << 16 | Int(d[at + 3]) << 24 : -1
    }

    private struct Item {
        let local: Int
        let flags: Int
        let method: Int
        let crc: Int
        let packed: Int
        let size: Int
        let name: ArraySlice<UInt8>
    }

    /// The entries of a zip file, inflated, when the file is one and nothing in it is left unexplained: the end record closes the
    /// file, the directory sits just before it and holds the entries it counts, the local entries follow one another from the first
    /// byte to the directory, each with the header and the sizes its directory entry has, and each inflates to exactly its size and
    /// its CRC-32 and uses exactly its packed bytes. Nil when it is not, and when the entries hold more than `budget`.
    static func unzip(_ d: [UInt8], _ budget: Int) -> [[UInt8]]? {
        var end = -1
        var i = d.count - 22
        while i >= 0 && i >= d.count - 22 - 0xFFFF {
            if d[i] == 0x50 && d[i + 1] == 0x4B && d[i + 2] == 5 && d[i + 3] == 6 && i + 22 + u16(d, i + 20) == d.count {
                end = i
                break
            }
            i -= 1
        }
        if end < 0 { return nil }
        let count = u16(d, end + 10), size = u32(d, end + 12), offset = u32(d, end + 16)
        // One disk, the classic record (zip64 is not read here), and the directory closing right before the end record.
        if u16(d, end + 4) != 0 || u16(d, end + 6) != 0 || u16(d, end + 8) != count || count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { return nil }
        if end >= 20 && u32(d, end - 20) == 0x0706_4B50 { return nil }
        if offset + size != end { return nil }

        var items: [Item] = []
        var at = offset
        for _ in 0..<count {
            let name = u16(d, at + 28), extra = u16(d, at + 30), comment = u16(d, at + 32)
            if u32(d, at) != 0x0201_4B50 || name < 0 || extra < 0 || comment < 0 || u16(d, at + 34) != 0 { return nil }
            let next = at + 46 + name + extra + comment
            if next > end { return nil }
            let flags = u16(d, at + 8), method = u16(d, at + 10), packed = u32(d, at + 20), plain = u32(d, at + 24)
            // Encrypted, or sizes and offsets that only a zip64 record can hold.
            if flags & 0x41 != 0 || packed == 0xFFFF_FFFF || plain == 0xFFFF_FFFF || u32(d, at + 42) == 0xFFFF_FFFF { return nil }
            items.append(Item(local: u32(d, at + 42), flags: flags, method: method, crc: u32(d, at + 16), packed: packed, size: plain,
                              name: d[(at + 46)..<(at + 46 + name)]))
            at = next
        }
        if at != end { return nil }

        var found: [[UInt8]] = []
        var cursor = 0, total = 0
        for item in items.sorted(by: { $0.local < $1.local }) {
            if item.local != cursor || u32(d, cursor) != 0x0403_4B50 { return nil }
            let name = u16(d, cursor + 26), extra = u16(d, cursor + 28)
            if name != item.name.count || extra < 0 || u16(d, cursor + 6) != item.flags || u16(d, cursor + 8) != item.method { return nil }
            let start = cursor + 30 + name + extra
            if start > offset || !d[(cursor + 30)..<(cursor + 30 + name)].elementsEqual(item.name) { return nil }
            let stop = start + item.packed
            if stop > offset { return nil }
            let descriptor = item.flags & 8 != 0
            if !descriptor && (u32(d, cursor + 14) != item.crc || u32(d, cursor + 18) != item.packed || u32(d, cursor + 22) != item.size) { return nil }
            let localCrc = u32(d, cursor + 14)
            if descriptor && localCrc != 0 && localCrc != item.crc { return nil }
            cursor = stop
            if descriptor {
                let at2 = u32(d, cursor) == 0x0807_4B50 ? cursor + 4 : cursor
                if u32(d, at2) != item.crc || u32(d, at2 + 4) != item.packed || u32(d, at2 + 8) != item.size { return nil }
                cursor = at2 + 12
            }
            if cursor > offset { return nil }
            total += item.size
            if total > budget { return nil }
            guard let bytes = entry(d, start, item) else { return nil }
            found.append(bytes)
        }
        return cursor == offset ? found : nil
    }

    private static func entry(_ d: [UInt8], _ start: Int, _ item: Item) -> [UInt8]? {
        let bytes: [UInt8]
        if item.method == 0 {
            if item.packed != item.size { return nil }
            bytes = Array(d[start..<(start + item.packed)])
        } else if item.method == 8 {
            if item.packed == 0 && item.size == 0 { return [] }
            // The stream ends where the size says, having used the packed bytes and no others.
            let output = FilterBuffer(item.size)
            var end = start
            guard let ended = try? Flate.inflate(d, start, output, end: &end), ended, output.count == item.size, end == start + item.packed else { return nil }
            bytes = output.toArray()
        } else {
            return nil
        }
        return Int(ExportZip.crc32(bytes)) == item.crc ? bytes : nil
    }

    /// The members of a gzip file, inflated and joined as GZipStream joins them, when each has a header zlib accepts (no reserved
    /// flag, the header checksum right when there is one), a deflate stream that ends, and a trailer that is its own. Zero bytes after
    /// the last member are padding; anything else after one is not a member, and the file is not read. Nil when it is not read, and
    /// when the members hold more than `budget`.
    static func gunzip(_ d: [UInt8], _ budget: Int) -> [UInt8]? {
        var all: [UInt8] = []
        var at = 0
        repeat {
            if at + 18 > d.count || d[at] != 0x1F || d[at + 1] != 0x8B || d[at + 2] != 8 || d[at + 3] & 0xE0 != 0 { return nil }
            let flags = Int(d[at + 3])
            var p = at + 10
            if flags & 4 != 0 {
                let extra = u16(d, p)
                if extra < 0 { return nil }
                p += 2 + extra
            }
            for bit in [8, 16] where flags & bit != 0 {
                while p < d.count && d[p] != 0 { p += 1 }
                p += 1
            }
            if flags & 2 != 0 {
                if p + 2 > d.count || u16(d, p) != Int(ExportZip.crc32(Array(d[at..<p])) & 0xFFFF) { return nil }
                p += 2
            }
            if p >= d.count { return nil }
            let output = FilterBuffer(budget - all.count)
            var end = p
            guard let ended = try? Flate.inflate(d, p, output, end: &end), ended else { return nil }
            let bytes = output.toArray()
            if end + 8 > d.count || u32(d, end) != Int(ExportZip.crc32(bytes)) || u32(d, end + 4) != bytes.count & 0xFFFF_FFFF { return nil }
            all += bytes
            at = end + 8
            if at < d.count && d[at...].allSatisfy({ $0 == 0 }) { at = d.count }
        } while at < d.count
        return all
    }
}
