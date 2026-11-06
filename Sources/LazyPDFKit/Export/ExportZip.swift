import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportZip.cs, from Lazy Scan's ExportZip.cs, with deflate in place of stored
// entries.

struct ExportZipEntry {
    let name: String
    let data: [UInt8]

    init(_ name: String, _ data: [UInt8]) {
        self.name = name
        self.data = data
    }
}

/// A minimal zip writer for the Office packages: entries deflated when that is smaller, dated 1980-01-01, in the order
/// given, with a CRC-32 per entry. No zip64; a package past 65534 entries or 1 GB is refused with a `PdfReadException`.
enum ExportZip {
    // 1980-01-01, the earliest date a zip holds: the same bytes on every save.
    private static let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1

    // A MemoryStream stops at 2 GB, so the package is refused well before.
    private static let maxPackage = 1 << 30

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    // 0xFFFF in the end record is the zip64 marker, so that count is already too many.
    private static let maxEntries = Int(UInt16.max) - 1

    private static func tooLarge() -> PdfReadException { PdfReadException(.unsupported, ExportText.tooLarge) }

    /// Refuses a package of more entries than the end record can count, for a writer to ask before it builds them.
    static func checkCount(_ entries: Int) throws {
        if entries > maxEntries { throw tooLarge() }
    }

    /// The CRC-32 of zip and PNG (polynomial 0xEDB88320, reflected); pass the previous value to continue.
    static func crc32(_ data: [UInt8], _ crc: UInt32 = 0) -> UInt32 {
        var c = crc ^ 0xFFFFFFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    static func make(_ entries: [ExportZipEntry]) throws -> [UInt8] {
        try checkCount(entries.count)
        var total = 0
        for e in entries { total += e.data.count }
        if total > maxPackage { throw tooLarge() }
        var output: [UInt8] = []
        var central: [UInt8] = []
        for entry in entries {
            let name = Array(entry.name.utf8)
            let flags: UInt16 = name.contains { $0 > 0x7F } ? 0x0800 : 0
            let crc = crc32(entry.data)
            var stored = entry.data
            var method: UInt16 = 0
            if !entry.data.isEmpty, let packed = deflate(entry.data), packed.count < entry.data.count {
                stored = packed
                method = 8
            }
            let offset = output.count
            if offset > Int(UInt32.max) || stored.count > Int(UInt32.max) { throw tooLarge() }
            let version: UInt16 = method == 8 ? 20 : 10

            writeUInt32(&output, 0x04034B50)
            writeUInt16(&output, version)
            writeUInt16(&output, flags)
            writeUInt16(&output, method)
            writeUInt16(&output, 0)
            writeUInt16(&output, dosDate)
            writeUInt32(&output, crc)
            writeUInt32(&output, UInt32(truncatingIfNeeded: stored.count))
            writeUInt32(&output, UInt32(truncatingIfNeeded: entry.data.count))
            writeUInt16(&output, UInt16(truncatingIfNeeded: name.count))
            writeUInt16(&output, 0)
            output += name
            output += stored

            writeUInt32(&central, 0x02014B50)
            writeUInt16(&central, 20)
            writeUInt16(&central, version)
            writeUInt16(&central, flags)
            writeUInt16(&central, method)
            writeUInt16(&central, 0)
            writeUInt16(&central, dosDate)
            writeUInt32(&central, crc)
            writeUInt32(&central, UInt32(truncatingIfNeeded: stored.count))
            writeUInt32(&central, UInt32(truncatingIfNeeded: entry.data.count))
            writeUInt16(&central, UInt16(truncatingIfNeeded: name.count))
            writeUInt16(&central, 0)
            writeUInt16(&central, 0)
            writeUInt16(&central, 0)
            writeUInt16(&central, 0)
            writeUInt32(&central, 0)
            writeUInt32(&central, UInt32(truncatingIfNeeded: offset))
            central += name
        }

        let centralOffset = output.count
        output += central
        let centralSize = output.count - centralOffset
        if output.count > Int(UInt32.max) { throw tooLarge() }

        writeUInt32(&output, 0x06054B50)
        writeUInt16(&output, 0)
        writeUInt16(&output, 0)
        writeUInt16(&output, UInt16(truncatingIfNeeded: entries.count))
        writeUInt16(&output, UInt16(truncatingIfNeeded: entries.count))
        writeUInt32(&output, UInt32(truncatingIfNeeded: centralSize))
        writeUInt32(&output, UInt32(truncatingIfNeeded: centralOffset))
        writeUInt16(&output, 0)
        return output
    }

    // The engine's deflate writes zlib: the two header bytes and the Adler-32 around the blocks are cut off.
    private static func deflate(_ data: [UInt8]) -> [UInt8]? {
        let packed = PdfFilterEncoders.flate(data, .optimal)
        return packed.count > 6 ? Array(packed[2..<(packed.count - 4)]) : nil
    }

    private static func writeUInt16(_ output: inout [UInt8], _ value: UInt16) {
        output.append(UInt8(truncatingIfNeeded: value))
        output.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func writeUInt32(_ output: inout [UInt8], _ value: UInt32) {
        output.append(UInt8(truncatingIfNeeded: value))
        output.append(UInt8(truncatingIfNeeded: value >> 8))
        output.append(UInt8(truncatingIfNeeded: value >> 16))
        output.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
