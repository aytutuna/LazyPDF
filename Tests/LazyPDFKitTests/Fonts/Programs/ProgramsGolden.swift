import Foundation
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Fonts/Programs/ProgramsGolden.cs. The dumps are text, one fact per line;
// numbers go through PdfNumber so that both sides print the same digits. The enum names are the C# ones.
enum ProgramsGolden {
    private static func n(_ v: Double) -> String { PdfNumber(v).text }

    private static func b(_ v: Bool) -> String { v ? "true" : "false" }

    private static func s(_ v: String?) -> String { v ?? "null" }

    private static func box(_ v: GlyphBounds?) -> String {
        guard let v else { return "null" }
        return "\(n(v.xMin)) \(n(v.yMin)) \(n(v.xMax)) \(n(v.yMax))"
    }

    private static func hex(_ d: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var text = ""
        for byte in d {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 15)])
        }
        return text
    }

    private static func seg(_ s: OutlineSegment) -> String {
        switch s.op {
        case .move: return "M \(n(s.x)) \(n(s.y))"
        case .line: return "L \(n(s.x)) \(n(s.y))"
        case .quad: return "Q \(n(s.x1)) \(n(s.y1)) \(n(s.x)) \(n(s.y))"
        case .cubic: return "C \(n(s.x1)) \(n(s.y1)) \(n(s.x2)) \(n(s.y2)) \(n(s.x)) \(n(s.y))"
        case .close: return "Z"
        }
    }

    private static func outline(_ o: GlyphOutline?) -> String {
        guard let o else { return "null" }
        return o.isEmpty ? "empty" : o.segments.map(seg).joined(separator: " ")
    }

    private static func hexLines(_ out: inout String, _ data: [UInt8]) {
        let digits = Array(hex(data))
        var i = 0
        while i < digits.count {
            out += "  " + String(digits[i..<min(i + 128, digits.count)]) + "\n"
            i += 128
        }
    }

    private static func pairs(_ map: [Int: Int]) -> String {
        map.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
    }

    private static func subsetStatus(_ status: SubsetStatus) -> String {
        switch status {
        case .ok: return "Ok"
        case .unreadable: return "Unreadable"
        case .notTrueType: return "NotTrueType"
        case .embeddingForbidden: return "EmbeddingForbidden"
        case .subsettingForbidden: return "SubsettingForbidden"
        }
    }

    private static func embedStatus(_ status: EmbedStatus) -> String {
        switch status {
        case .ok: return "Ok"
        case .unreadable: return "Unreadable"
        case .noOutlines: return "NoOutlines"
        case .embeddingForbidden: return "EmbeddingForbidden"
        }
    }

    static func fixture(_ name: String, file: String = #filePath) throws -> [UInt8] {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        url = url.appendingPathComponent("Fixtures").appendingPathComponent("golden").appendingPathComponent("programs").appendingPathComponent(name)
        return [UInt8](try Data(contentsOf: url))
    }

    static func standardNamesDump() -> String {
        var out = ""
        for i in 0..<StandardNames.cffStrings.count { out += "cff \(i) \(StandardNames.cffStrings[i])\n" }
        for i in 0..<StandardNames.macGlyphs.count { out += "mac \(i) \(StandardNames.macGlyphs[i])\n" }
        for c in 0..<256 { out += "std \(c) \(s(StandardNames.standardEncoding[c])) \(StandardNames.standardEncodingSids[c])\n" }
        return out
    }

    static func trueType(_ data: [UInt8]) -> String {
        var out = ""
        func l(_ text: String) { out += text + "\n" }
        guard let f = TrueTypeFont.tryParse(data) else { return "unreadable\n" }
        l("collection \(TrueTypeFont.collectionCount(data))")
        l("upem \(f.unitsPerEm) glyphs \(f.glyphCount) ascent \(f.ascent) descent \(f.descent) lineGap \(f.lineGap)")
        l("cap \(f.capHeight) x \(f.xHeight) bounds \(box(f.fontBounds)) italic \(n(f.italicAngle)) fixed \(b(f.isFixedPitch)) bold \(b(f.isBoldStyle))")
        l("weight \(f.weightClass) fsType \(f.fsType) embedding \(b(f.embeddingAllowed)) subsetting \(b(f.subsettingAllowed)) cff \(b(f.isCff)) outlines \(b(f.hasOutlines))")
        l("family \(s(f.familyName)) ps \(s(f.postScriptName))")
        for t in ["glyf", "loca", "cmap", "post", "name", "cvt ", "fpgm", "prep", "CFF ", "kern"] {
            l("table \(t) \(b(f.hasTable(t)))")
        }
        for cp in [0x20, 0x41, 0x42, 0x43, 0xC0, 0x11F, 0x130, 0x131, 0x1F600, 0x4E2D, -1, 0x10FFFF] {
            l("cp \(cp) \(f.glyphForCodePoint(cp)) cmap31 \(f.glyphForCmap(3, 1, cp)) cmap10 \(f.glyphForCmap(1, 0, cp)) cmap310 \(f.glyphForCmap(3, 10, cp)) cmap00 \(f.glyphForCmap(0, 0, cp))")
        }
        l("hasCmap 31 \(b(f.hasCmap(3, 1))) 10 \(b(f.hasCmap(1, 0))) 310 \(b(f.hasCmap(3, 10))) 05 \(b(f.hasCmap(0, 5))) 30 \(b(f.hasCmap(3, 0)))")
        for (cp, vs) in [(0x41, 0xFE00), (0x42, 0xFE00), (0x43, 0xFE00), (0x11F, 0xFE00), (0x11F, 0xFE01)] {
            l("variation \(cp) \(vs) \(f.glyphForVariation(cp, vs))")
        }
        for g in -1...f.glyphCount {
            l("glyph \(g) name \(s(f.glyphName(g))) advance \(f.getAdvance(g)) lsb \(f.getLeftSideBearing(g)) box \(box(f.getBounds(g)))")
            l("  \(outline(f.getOutline(g)))")
        }
        for name in [".notdef", "A", "Alt", "acutecomb", "space", "nothing"] {
            l("forName \(name) \(f.glyphForName(name))")
        }
        return out
    }

    private static func withFsType(_ font: [UInt8], _ fsType: Int) -> [UInt8] {
        var copy = font
        let os2 = ProgramFonts.tableOffset(copy, "OS/2")
        copy[os2 + 8] = UInt8(truncatingIfNeeded: fsType >> 8)
        copy[os2 + 9] = UInt8(truncatingIfNeeded: fsType)
        return copy
    }

    static func subset(_ data: [UInt8]) -> String {
        var out = ""
        func l(_ text: String) { out += text + "\n" }
        let cases: [(String, [UInt8], [Int])] = [
            ("composite", data, [3]),
            ("two", data, [2, 5]),
            ("matched", data, [6]),
            ("none", data, []),
            ("odd", data, [1, 99999, -4, 4]),
            ("forbidden", withFsType(data, 2), [1]),
            ("whole", withFsType(data, 0x100), [1]),
            ("garbage", [1, 2, 3], [1]),
        ]
        for (label, font, ids) in cases {
            let r = TrueTypeSubsetter.subset(font, ids)
            l("subset \(label) \(subsetStatus(r.status)) map \(pairs(r.glyphMap)) length \(r.data.count)")
            hexLines(&out, r.data)
            if r.status == .ok, let again = TrueTypeFont.tryParse(r.data) {
                l("  parsed glyphs \(again.glyphCount) ps \(s(again.postScriptName)) family \(s(again.familyName)) upem \(again.unitsPerEm)")
                for (_, to) in r.glyphMap.sorted(by: { $0.key < $1.key }) {
                    l("  glyph \(to) advance \(again.getAdvance(to)) box \(box(again.getBounds(to))) \(outline(again.getOutline(to)))")
                }
            }
        }
        return out
    }

    static func embedded(_ data: [UInt8]) -> String {
        var out = ""
        func l(_ text: String) { out += text + "\n" }
        let cases: [(String, [UInt8], [String])] = [
            ("latin", data, ["AB\u{C0} \u{11F}\u{130}"]),
            ("missing", data, ["A\u{4E2D}\u{1F600}B", "\t"]),
            ("shared", data, ["\u{131}\u{11F}"]),
            ("empty", data, []),
            ("forbidden", withFsType(data, 2), ["A"]),
            ("whole", withFsType(data, 0x100), ["AB\u{C0}"]),
            ("garbage", [UInt8](repeating: 0, count: 200), ["A"]),
        ]
        for (label, font, texts) in cases {
            let (built, status) = EmbeddedFontBuilder.build(font, texts)
            l("embed \(label) \(embedStatus(status))")
            guard let e = built else { continue }
            l("  base \(e.baseFont) cff \(b(e.isCff)) subset \(b(e.isSubset)) dw \(e.defaultWidth) program \(e.program.count)")
            hexLines(&out, e.program)
            l("  widths " + e.widths.map { "\($0.firstCid)[\($0.widths.map { String($0) }.joined(separator: ","))]" }.joined(separator: " "))
            let d = e.descriptor
            l("  descriptor flags \(d.flags) bbox \(d.fontBBox.map { String($0) }.joined(separator: ",")) italic \(n(d.italicAngle)) ascent \(d.ascent) descent \(d.descent) cap \(d.capHeight) stemV \(d.stemV)")
            l("  codes \(pairs(e.codes))")
            l("  missing \(e.missing.map { String($0) }.joined(separator: ","))")
            l("  encode \(hex(e.encode(texts.joined())))")
            l("  toUnicode \(pairs(e.toUnicode()))")
        }
        return out
    }

    static func cff(_ input: String) -> String {
        var out = ""
        func l(_ text: String) { out += text + "\n" }
        let fonts: [(String, [UInt8])] = [
            ("name", CffBuilder.nameKeyed()),
            ("cid", CffBuilder.cidKeyed()),
            ("cidMatrix", CffBuilder.cidKeyed([3, 0, 0, 3, 0, 0], [2, 0, 0, 2, 0, 0])),
        ]
        for (label, data) in fonts {
            guard let f = CffFont.tryParse(data) else { return "unreadable\n" }
            l("font \(label) name \(f.name) cid \(b(f.isCid)) glyphs \(f.glyphCount) matrix \(f.fontMatrix.map(n).joined(separator: ",")) bounds \(box(f.fontBounds))")
            for g in -1...f.glyphCount {
                l("  glyph \(g) name \(s(f.glyphName(g))) width \(n(f.getWidth(g))) cid \(f.cidForGlyph(g)) \(outline(f.getOutline(g)))")
            }
            l("  names \(["A", "B", "custom", ".notdef", "nothing"].map { String(f.glyphForName($0)) }.joined(separator: ","))")
            l("  codes \((60..<70).map { String(f.glyphForCode($0)) }.joined(separator: ","))")
            l("  cids \([-1, 0, 1, 2, 3, 10, 11, 12, 500, 501].map { String(f.glyphForCid($0)) }.joined(separator: ","))")
        }

        var count = 0
        for line in input.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("# ") {
            var parts: [CodePart] = []
            for token in line.split(separator: " ", omittingEmptySubsequences: false) {
                if let v = Int32(token) {
                    parts.append(.number(Int(v)))
                } else if token.hasPrefix("raw:") {
                    parts.append(.raw(bytes(fromHex: String(token.dropFirst(4)))))
                } else {
                    parts.append(.op(String(token)))
                }
            }
            parts.append("return")
            guard let f = CffFont.tryParse(CffBuilder.nameKeyed(CffBuilder.code(parts))) else { return "unreadable\n" }
            count += 1
            l("subr \(count) \(line)")
            l("  width \(n(f.getWidth(2))) \(outline(f.getOutline(2)))")
        }
        return out
    }

    private static func bytes(fromHex text: String) -> [UInt8] {
        let digits = Array(text.utf8)
        var result: [UInt8] = []
        var i = 0
        while i + 1 < digits.count {
            result.append(UInt8(String(decoding: digits[i...i + 1], as: UTF8.self), radix: 16) ?? 0)
            i += 2
        }
        return result
    }

    static func type1() -> String {
        var out = ""
        func l(_ text: String) { out += text + "\n" }
        let variants: [(Type1Wrapper, String, Int, Bool)] = [
            (.binary, "Binary", 4, false), (.hex, "Hex", 4, false), (.pfb, "Pfb", 4, false),
            (.binary, "Binary", 4, true), (.binary, "Binary", 0, false), (.hex, "Hex", -1, true),
        ]
        for (wrapper, label, lenIV, bar) in variants {
            guard let f = Type1Font.tryParse(Type1Builder.build(wrapper, lenIV, bar)) else { return "unreadable\n" }
            l("font \(label) \(lenIV) \(b(bar)) name \(f.fontName) matrix \(f.fontMatrix.map(n).joined(separator: ",")) bounds \(box(f.fontBounds))")
            let codes = (0..<256).filter { f.builtInEncoding[$0] != nil }.map { "\($0):\(f.builtInEncoding[$0] ?? "")" }
            l("  encoding \(codes.joined(separator: ","))")
            for name in f.glyphNames + ["missing"] {
                l("  glyph \(name) has \(b(f.hasGlyph(name))) width \(n(f.getWidth(name))) \(outline(f.getOutline(name)))")
            }
        }
        return out
    }

    // The damage is a fixed linear congruential sequence, so both sides break the same bytes.
    private static func damage(_ source: [UInt8], _ round: Int) -> [UInt8] {
        var state = UInt32(1000 + round)
        func next() -> UInt32 {
            state = state &* 1664525 &+ 1013904223
            return state >> 8
        }
        var data = source
        for _ in 0..<(1 + round % 6) {
            let at = Int(next() % UInt32(data.count))
            data[at] = UInt8(next() & 0xFF)
        }
        return data
    }

    static func damaged(_ sfnt: [UInt8]) -> String {
        var out = ""
        func l(_ text: String) { out += text + "\n" }
        for round in 0..<300 {
            guard let f = TrueTypeFont.tryParse(damage(sfnt, round)) else {
                l("ttf \(round) null")
                continue
            }
            var segments = 0
            var advances = 0
            for g in 0..<min(f.glyphCount, 64) {
                segments += f.getOutline(g)?.segments.count ?? 0
                advances += f.getAdvance(g)
            }
            l("ttf \(round) glyphs \(f.glyphCount) upem \(f.unitsPerEm) ascent \(f.ascent) cap \(f.capHeight) segments \(segments) advances \(advances) ps \(s(f.postScriptName)) A \(f.glyphForCodePoint(0x41)) E \(f.glyphForCodePoint(0xC0)) name \(s(f.glyphName(3)))")
        }
        let sources: [(String, [UInt8])] = [("cff", CffBuilder.nameKeyed()), ("cid", CffBuilder.cidKeyed())]
        for (label, source) in sources {
            for round in 0..<300 {
                guard let f = CffFont.tryParse(damage(source, round)) else {
                    l("\(label) \(round) null")
                    continue
                }
                var segments = 0
                var widths = 0.0
                for g in 0..<min(f.glyphCount, 16) {
                    segments += f.getOutline(g)?.segments.count ?? 0
                    widths += f.getWidth(g)
                }
                l("\(label) \(round) glyphs \(f.glyphCount) cid \(b(f.isCid)) name \(f.name) segments \(segments) widths \(n(widths)) matrix \(f.fontMatrix.map(n).joined(separator: ",")) g1 \(s(f.glyphName(1))) c500 \(f.glyphForCid(500))")
            }
        }
        let type1 = Type1Builder.build(.binary)
        for round in 0..<300 {
            guard let f = Type1Font.tryParse(damage(type1, round)) else {
                l("type1 \(round) null")
                continue
            }
            var segments = 0
            var widths = 0.0
            for name in f.glyphNames {
                segments += f.getOutline(name)?.segments.count ?? 0
                widths += f.getWidth(name)
            }
            l("type1 \(round) name \(f.fontName) glyphs \(f.glyphNames.count) segments \(segments) widths \(n(widths)) A \(s(f.builtInEncoding[65]))")
        }
        return out
    }
}
