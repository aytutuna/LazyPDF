import Foundation

// Twin of windows/LazyPDF.Core/Content/PdfFont.Glyphs.cs: whether the embedded program draws a character.

extension PdfFont {
    /// Whether the embedded program has an outline for the character. True for a font with no program of its own (the
    /// viewer draws it), and for white space, whose glyph is empty.
    func canDraw(_ ch: FontChar) -> Bool {
        guard isEmbedded, let program else { return true }
        let blank = ch.unicode.map { !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0.properties.isWhitespace } } ?? false
        if isComposite {
            if let tt = program.trueType, tt.cff == nil {
                let gid = glyphOf(ch.cid)
                return gid > 0 ? tt.getBounds(gid) != nil || blank : blank
            }
            if let cff = program.cff {
                let gid = cff.isCid ? cff.glyphForCid(ch.cid) : ch.cid
                return gid > 0 ? cff.getOutline(gid).map { !$0.isEmpty } ?? false || blank : blank
            }
            return true
        }
        let code = ch.code
        // The C# indexes its glyph names with the code; a character of another font could carry one past 255.
        if code < 0 || code > 255 { return blank }
        if let simple = program.trueType, simple.cff == nil {
            let gid = trueTypeGlyph(simple, code)
            return gid > 0 ? simple.getBounds(gid) != nil || blank : blank
        }
        let name = names[code]
        if let t1 = program.type1 {
            guard let name else { return false }
            return t1.hasGlyph(name)
        }
        if let bare = program.cff {
            var gid = name.map { bare.glyphForName($0) } ?? 0
            if gid == 0 { gid = bare.glyphForCode(code) }
            return gid > 0 ? bare.getOutline(gid).map { !$0.isEmpty } ?? false || blank : blank
        }
        return true
    }
}
