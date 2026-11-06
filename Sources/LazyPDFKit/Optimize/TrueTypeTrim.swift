import Foundation

// Twin of windows/LazyPDF.Core/Optimize/TrueTypeTrim.cs: empties the outlines of the glyphs a font is not used for.
// Glyph numbers, the cmap and the metrics stay as they were, so no code in a PDF has to change; that is why this is
// not the renumbering subsetter in Fonts/.

enum TrueTypeTrim {
    private static let kept = ["OS/2", "cmap", "cvt ", "fpgm", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post", "prep"]
    private static let maxComponents = 256

    private static func u16(_ data: [UInt8], _ at: Int) -> Int { Int(data[at]) << 8 | Int(data[at + 1]) }

    private static func u32(_ data: [UInt8], _ at: Int) -> Int { u16(data, at) << 16 | u16(data, at + 2) }

    static func trim(_ font: [UInt8], _ glyphs: Set<Int>) -> [UInt8]? {
        if font.count < 12 { return nil }
        let version = u32(font, 0)
        if version != 0x00010000 && version != 0x74727565 { return nil }
        let count = u16(font, 4)
        if 12 + 16 * count > font.count { return nil }
        var tables: [String: [UInt8]] = [:]
        for i in 0..<count {
            let at = 12 + 16 * i
            let tag = Latin1.string(Array(font[at..<at + 4]))
            let offset = u32(font, at + 8)
            let length = u32(font, at + 12)
            if offset + length > font.count { return nil }
            if kept.contains(tag) { tables[tag] = Array(font[offset..<offset + length]) }
        }
        guard var head = tables["head"], let maxp = tables["maxp"], let loca = tables["loca"], let glyf = tables["glyf"],
              head.count >= 54, maxp.count >= 6 else { return nil }
        let numGlyphs = u16(maxp, 4)
        if numGlyphs == 0 { return nil }
        let longLoca = u16(head, 50) != 0
        if loca.count < (numGlyphs + 1) * (longLoca ? 4 : 2) { return nil }

        func start(_ glyph: Int) -> Int { longLoca ? u32(loca, 4 * glyph) : 2 * u16(loca, 2 * glyph) }
        func range(_ glyph: Int) -> (start: Int, length: Int) {
            let from = start(glyph)
            let to = start(glyph + 1)
            return from < 0 || to <= from || to > glyf.count ? (0, 0) : (from, to - from)
        }

        var keep: Set<Int> = [0]
        var queue = [0]
        for g in glyphs.sorted() where g > 0 && g < numGlyphs {
            if keep.insert(g).inserted { queue.append(g) }
        }
        var next = 0
        while next < queue.count {
            let (first, length) = range(queue[next])
            next += 1
            // A negative contour count marks a composite glyph.
            if length < 10 || Int16(truncatingIfNeeded: u16(glyf, first)) >= 0 { continue }
            var p = first + 10
            let end = first + length
            var parts = 0
            while parts < maxComponents && p + 4 <= end {
                let flags = u16(glyf, p)
                let part = u16(glyf, p + 2)
                if part < numGlyphs && keep.insert(part).inserted { queue.append(part) }
                p += 4 + ((flags & 1) != 0 ? 4 : 2) + ((flags & 8) != 0 ? 2 : (flags & 0x40) != 0 ? 4 : (flags & 0x80) != 0 ? 8 : 0)
                if (flags & 0x20) == 0 { break }
                parts += 1
            }
        }

        var newGlyf: [UInt8] = []
        var newLoca = Array(repeating: UInt8(0), count: 4 * (numGlyphs + 1))
        func put(_ value: Int, _ at: Int) {
            let v = UInt32(truncatingIfNeeded: value)
            for k in 0..<4 { newLoca[at + k] = UInt8(truncatingIfNeeded: v >> UInt32(24 - 8 * k)) }
        }
        for g in 0..<numGlyphs {
            put(newGlyf.count, 4 * g)
            if !keep.contains(g) { continue }
            let (first, length) = range(g)
            newGlyf += glyf[first..<first + length]
            while newGlyf.count % 4 != 0 { newGlyf.append(0) }
        }
        put(newGlyf.count, 4 * numGlyphs)
        tables["glyf"] = newGlyf
        tables["loca"] = newLoca
        head[50] = 0
        head[51] = 1
        tables["head"] = head
        return assemble(UInt32(truncatingIfNeeded: version), tables)
    }

    private static func assemble(_ version: UInt32, _ tables: [String: [UInt8]]) -> [UInt8] {
        // SortedDictionary with StringComparer.Ordinal; the tags are Latin-1.
        let ordered = tables.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }
        let n = ordered.count
        let entrySelector = Int.bitWidth - 1 - n.leadingZeroBitCount
        var header = Array(repeating: UInt8(0), count: 12 + 16 * n)
        func put32(_ value: UInt32, _ at: Int) {
            for k in 0..<4 { header[at + k] = UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * k)) }
        }
        func put16(_ value: Int, _ at: Int) {
            header[at] = UInt8(truncatingIfNeeded: value >> 8)
            header[at + 1] = UInt8(truncatingIfNeeded: value)
        }
        put32(version, 0)
        put16(n, 4)
        put16(16 << entrySelector, 6)
        put16(entrySelector, 8)
        put16(16 * n - (16 << entrySelector), 10)
        var body: [UInt8] = []
        var position = header.count
        var adjustAt = -1
        for (entry, table) in ordered.enumerated() {
            let (tag, data) = table
            if tag == "head" { adjustAt = position + 8 }
            let at = 12 + 16 * entry
            let name = Latin1.bytes(tag)
            for k in 0..<4 { header[at + k] = k < name.count ? name[k] : 0 }
            put32(tag == "head" ? checksum(data, skip: 8) : checksum(data), at + 4)
            put32(UInt32(truncatingIfNeeded: position), at + 8)
            put32(UInt32(truncatingIfNeeded: data.count), at + 12)
            body += data
            let pad = (4 - data.count % 4) % 4
            body += Array(repeating: UInt8(0), count: pad)
            position += data.count + pad
        }
        var file = header + body
        if adjustAt >= 0 && adjustAt + 4 <= file.count {
            for k in 0..<4 { file[adjustAt + k] = 0 }
            let adjustment = 0xB1B0AFBA &- checksum(file)
            for k in 0..<4 { file[adjustAt + k] = UInt8(truncatingIfNeeded: adjustment >> UInt32(24 - 8 * k)) }
        }
        return file
    }

    // With skip set, the word at that offset counts as zero (the head table's checksum adjustment).
    private static func checksum(_ data: [UInt8], skip: Int = -1) -> UInt32 {
        var sum: UInt32 = 0
        var i = 0
        while i < data.count {
            var word: UInt32 = 0
            for k in 0..<4 { word = word << 8 | (i + k < data.count ? UInt32(data[i + k]) : 0) }
            if i != skip { sum = sum &+ word }
            i += 4
        }
        return sum
    }
}
