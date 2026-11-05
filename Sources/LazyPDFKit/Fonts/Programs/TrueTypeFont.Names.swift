import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/TrueTypeFont.Names.cs: glyph names of an sfnt font.

extension TrueTypeFont {
    /// Glyph name from 'post' (formats 1 and 2) or the CFF charset, nil when the font has none for it.
    public func glyphName(_ glyphId: Int) -> String? {
        let names = loadedGlyphNames()
        return glyphId >= 0 && glyphId < names.count ? names[glyphId] : nil
    }

    /// The first glyph with this name, 0 when there is none.
    public func glyphForName(_ name: String) -> Int {
        if nameToGlyph == nil {
            let names = loadedGlyphNames()
            var map: [String: Int] = [:]
            for g in 0..<names.count {
                if let n = names[g], map[n] == nil { map[n] = g }
            }
            nameToGlyph = map
        }
        return nameToGlyph?[name] ?? 0
    }

    private func loadedGlyphNames() -> [String?] {
        if let names = glyphNames { return names }
        let names = readGlyphNames()
        glyphNames = names
        return names
    }

    private func readGlyphNames() -> [String?] {
        let post = table("post")
        let format = post.u32(0)
        var names = [String?](repeating: nil, count: glyphCount)

        if format == 0x00010000 {
            var g = 0
            while g < names.count && g < StandardNames.macGlyphs.count {
                names[g] = StandardNames.macGlyphs[g]
                g += 1
            }
            return names
        }

        if format == 0x00020000 {
            let n = min(post.u16(32), (post.length - 34) / 2)
            var custom: [String] = []
            var p = 34 + 2 * n
            while p < post.length {
                let len = post.u8(p)
                if p + 1 + len > post.length { break }
                custom.append(Latin1.string(post.slice(p + 1, len).toArray()))
                p += 1 + len
            }
            var g = 0
            while g < n && g < names.count {
                let idx = post.u16(34 + 2 * g)
                if idx < StandardNames.macGlyphs.count {
                    names[g] = StandardNames.macGlyphs[idx]
                } else if idx - 258 < custom.count {
                    names[g] = custom[idx - 258]
                }
                g += 1
            }
            return names
        }

        if let cff {
            for g in 0..<names.count { names[g] = cff.glyphName(g) }
        }
        return names
    }
}
