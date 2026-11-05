import Foundation

// Twin of windows/LazyPDF.Core/Content/PdfFont.Metrics.cs: what the embedded font program itself says, for checks
// that set it against the dictionary.

extension PdfFont {
    /// The glyph name the encoding gives a code of a simple font.
    func glyphNameOf(_ code: Int) -> String? {
        isComposite || code < 0 || code > 255 ? nil : names[code]
    }

    /// The advance in 1/1000 em the font program gives a code of a simple font; nil without a program or the glyph.
    func programWidth(_ code: Int) -> Double? {
        guard !isComposite, code >= 0, code <= 255, let program else { return nil }
        if let own = program.width(code, names[code]) { return own }
        if let tt = program.trueType, tt.cff == nil {
            let gid = trueTypeGlyph(tt, code)
            if gid > 0 { return Double(tt.getAdvance(gid)) * 1000.0 / Double(tt.unitsPerEm) }
        }
        return nil
    }

    /// The advance in 1/1000 em the font program gives a CID of a composite font; nil without a program or the glyph.
    func programCidWidth(_ cid: Int) -> Double? {
        guard isComposite, let program else { return nil }
        if let tt = program.trueType, tt.cff == nil {
            let gid = glyphOf(cid)
            return gid >= 0 && gid < tt.glyphCount ? Double(tt.getAdvance(gid)) * 1000.0 / Double(tt.unitsPerEm) : nil
        }
        if let cff = program.cff {
            let gid = cff.isCid ? cff.glyphForCid(cid) : cid
            return gid > 0 || cid == 0 ? cff.getWidth(Swift.max(gid, 0)) * cff.fontMatrix[0] * 1000 : nil
        }
        return nil
    }
}
