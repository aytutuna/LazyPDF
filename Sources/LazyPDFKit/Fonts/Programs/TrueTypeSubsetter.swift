import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/TrueTypeSubsetter.cs: cuts a TrueType font down to some glyphs.
// Glyph IDs are renumbered densely in the order of the original IDs (.notdef stays 0), so a PDF font made from
// the result uses the new ID as the character code and an identity CIDToGIDMap. Composite glyphs pull in their
// components. Hinting is kept as is: the glyph programs are copied verbatim, so cvt, fpgm and prep stay with
// them. The output has head, hhea, maxp, hmtx, loca, glyf, post (no names), name, OS/2 and the hinting tables;
// no cmap, which a CIDFontType2 does not use.

public enum SubsetStatus {
    case ok
    case unreadable
    /// CFF outlines, or no glyf and loca: nothing this class can cut down.
    case notTrueType
    /// OS/2 fsType restricts embedding.
    case embeddingForbidden
    /// OS/2 fsType says the whole font must be embedded.
    case subsettingForbidden
}

/// `status` is ok, or why no font was made; the other members are empty unless it is ok. `data` is a TrueType font
/// for FontFile2. `glyphMap` is the original glyph ID to the glyph ID in `data`, for every glyph kept.
public struct SubsetResult {
    public let status: SubsetStatus
    public let data: [UInt8]
    public let glyphMap: [Int: Int]

    static func failed(_ status: SubsetStatus) -> SubsetResult {
        SubsetResult(status: status, data: [], glyphMap: [:])
    }
}

public enum TrueTypeSubsetter {
    private static let maxComponents = 512

    public static func subset<S: Sequence>(_ font: [UInt8], _ glyphIds: S, _ collectionIndex: Int = 0) -> SubsetResult where S.Element == Int {
        guard let f = TrueTypeFont.tryParse(font, collectionIndex) else { return .failed(.unreadable) }
        if f.isCff || !f.hasTable("glyf") || !f.hasTable("loca") { return .failed(.notTrueType) }
        if !f.embeddingAllowed { return .failed(.embeddingForbidden) }
        if !f.subsettingAllowed { return .failed(.subsettingForbidden) }

        let kept = close(f, glyphIds)
        var map: [Int: Int] = [:]
        for old in kept { map[old] = map.count }

        guard let (glyf, loca, longLoca) = buildGlyphs(f, kept, map) else { return .failed(.unreadable) }
        var tables: [String: [UInt8]] = [
            "glyf": glyf,
            "loca": loca,
            "hmtx": buildHmtx(f, kept),
            "head": buildHead(f, longLoca),
            "hhea": buildHhea(f, kept.count),
            "maxp": buildMaxp(f, kept.count),
            "post": buildPost(f),
        ]
        for t in ["OS/2", "cvt ", "fpgm", "prep"] where f.hasTable(t) {
            tables[t] = f.table(t).toArray()
        }
        if let name = buildName(f) { tables["name"] = name }

        return SubsetResult(status: .ok, data: assemble(tables), glyphMap: map)
    }

    private static func close<S: Sequence>(_ f: TrueTypeFont, _ requested: S) -> [Int] where S.Element == Int {
        var kept: Set<Int> = [0]
        var pending: [Int] = []
        for g in requested where g >= 0 && g < f.glyphCount {
            if kept.insert(g).inserted { pending.append(g) }
        }
        pending.append(0)

        while let next = pending.popLast() {
            let data = f.glyphData(next)
            for at in componentOffsets(data) {
                let component = data.u16(at)
                if component < f.glyphCount && kept.insert(component).inserted { pending.append(component) }
            }
        }
        return kept.sorted()
    }

    /// Positions of the component glyph IDs inside a composite glyph, none for a simple one.
    private static func componentOffsets(_ g: FontSpan) -> [Int] {
        var at: [Int] = []
        if g.length < 10 || g.i16(0) >= 0 { return at }
        var p = 10
        while p <= g.length - 4 && at.count < maxComponents {
            let flags = g.u16(p)
            at.append(p + 2)
            p += 4 + ((flags & 1) != 0 ? 4 : 2)
            if (flags & 0x8) != 0 {
                p += 2
            } else if (flags & 0x40) != 0 {
                p += 4
            } else if (flags & 0x80) != 0 {
                p += 8
            }
            if (flags & 0x20) == 0 { break }
        }
        return at
    }

    /// nil when the glyphs add up to more than an Int32 holds: loca offsets are 32 bits, and a loca whose glyphs
    /// overlap can make a font of a few hundred KB ask for gigabytes. The C# stops at about the same size, when
    /// its MemoryStream is too long.
    private static func buildGlyphs(_ f: TrueTypeFont, _ kept: [Int], _ map: [Int: Int]) -> (glyf: [UInt8], loca: [UInt8], long: Bool)? {
        var total = 0
        for old in kept {
            total += (f.glyphData(old).length + 3) & ~3
            if total > Int(Int32.max) { return nil }
        }

        var offsets = [Int](repeating: 0, count: kept.count + 1)
        var glyf: [UInt8] = []
        var i = 0
        for old in kept {
            offsets[i] = glyf.count
            i += 1
            var data = f.glyphData(old).toArray()
            let span = FontSpan(data)
            for at in componentOffsets(span) {
                FontBytes.putU16(&data, at, map[span.u16(at)] ?? 0)
            }
            glyf.append(contentsOf: data)
            while glyf.count % 4 != 0 { glyf.append(0) }
        }
        offsets[i] = glyf.count

        let longLoca = glyf.count >= 0x20000
        var loca = [UInt8](repeating: 0, count: offsets.count * (longLoca ? 4 : 2))
        for k in 0..<offsets.count {
            if longLoca {
                FontBytes.putU32(&loca, 4 * k, UInt32(truncatingIfNeeded: offsets[k]))
            } else {
                FontBytes.putU16(&loca, 2 * k, offsets[k] / 2)
            }
        }
        return (glyf, loca, longLoca)
    }

    private static func buildHmtx(_ f: TrueTypeFont, _ kept: [Int]) -> [UInt8] {
        var hmtx = [UInt8](repeating: 0, count: kept.count * 4)
        var i = 0
        for old in kept {
            FontBytes.putU16(&hmtx, 4 * i, f.getAdvance(old))
            FontBytes.putU16(&hmtx, 4 * i + 2, f.getLeftSideBearing(old) & 0xFFFF)
            i += 1
        }
        return hmtx
    }

    private static func buildHead(_ f: TrueTypeFont, _ longLoca: Bool) -> [UInt8] {
        var head = f.table("head").slice(0, 54).toArray()
        FontBytes.putU32(&head, 8, 0)
        FontBytes.putU16(&head, 50, longLoca ? 1 : 0)
        return head
    }

    private static func buildHhea(_ f: TrueTypeFont, _ count: Int) -> [UInt8] {
        let src = f.table("hhea")
        var hhea = [UInt8](repeating: 0, count: 36)
        let n = min(src.length, 36)
        for k in 0..<n { hhea[k] = src[k] }
        FontBytes.putU16(&hhea, 34, count)
        return hhea
    }

    private static func buildMaxp(_ f: TrueTypeFont, _ count: Int) -> [UInt8] {
        let src = f.table("maxp")
        var maxp = src.slice(0, min(src.length, 32)).toArray()
        FontBytes.putU16(&maxp, 4, count)
        return maxp
    }

    private static func buildPost(_ f: TrueTypeFont) -> [UInt8] {
        let src = f.table("post")
        var post = [UInt8](repeating: 0, count: 32)
        let n = min(src.length, 32)
        for k in 0..<n { post[k] = src[k] }
        FontBytes.putU32(&post, 0, 0x00030000)
        // memory hints are meaningless without the names
        for k in 16..<32 { post[k] = 0 }
        return post
    }

    private static func buildName(_ f: TrueTypeFont) -> [UInt8]? {
        guard let ps = f.postScriptName else { return nil }
        let records = [(id: 1, text: f.familyName ?? ps), (id: 4, text: ps), (id: 6, text: ps)]
        var storage: [UInt8] = []
        var name = [UInt8](repeating: 0, count: 6 + 12 * records.count)
        FontBytes.putU16(&name, 2, records.count)
        FontBytes.putU16(&name, 4, name.count)
        for i in 0..<records.count {
            var text: [UInt8] = []
            for unit in records[i].text.utf16 {
                text.append(UInt8(truncatingIfNeeded: unit >> 8))
                text.append(UInt8(truncatingIfNeeded: unit))
            }
            let r = 6 + 12 * i
            FontBytes.putU16(&name, r, 3)
            FontBytes.putU16(&name, r + 2, 1)
            FontBytes.putU16(&name, r + 4, 0x409)
            FontBytes.putU16(&name, r + 6, records[i].id)
            FontBytes.putU16(&name, r + 8, text.count)
            FontBytes.putU16(&name, r + 10, storage.count)
            storage.append(contentsOf: text)
        }
        return name + storage
    }

    private static func assemble(_ unsorted: [String: [UInt8]]) -> [UInt8] {
        // Ordinal order of the tags, which are ASCII.
        let tables = unsorted.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        let count = tables.count
        let entrySelector = Int.bitWidth - 1 - count.leadingZeroBitCount
        let searchRange = (1 << entrySelector) * 16

        var size = 12 + 16 * count
        for t in tables { size += (t.value.count + 3) & ~3 }
        var file = [UInt8](repeating: 0, count: size)
        FontBytes.putU32(&file, 0, 0x00010000)
        FontBytes.putU16(&file, 4, count)
        FontBytes.putU16(&file, 6, searchRange)
        FontBytes.putU16(&file, 8, entrySelector)
        FontBytes.putU16(&file, 10, count * 16 - searchRange)

        var dir = 12
        var offset = 12 + 16 * count
        var headAt = 0
        for (tag, data) in tables {
            let letters = Array(tag.utf8)
            for k in 0..<4 { file[dir + k] = letters[k] }
            FontBytes.putU32(&file, dir + 4, FontSpan(data).checksum())
            FontBytes.putU32(&file, dir + 8, UInt32(truncatingIfNeeded: offset))
            FontBytes.putU32(&file, dir + 12, UInt32(truncatingIfNeeded: data.count))
            for k in 0..<data.count { file[offset + k] = data[k] }
            if tag == "head" { headAt = offset }
            offset += (data.count + 3) & ~3
            dir += 16
        }
        FontBytes.putU32(&file, headAt + 8, 0xB1B0AFBA &- FontSpan(file).checksum())
        return file
    }
}
