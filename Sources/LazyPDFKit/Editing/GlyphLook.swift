import Foundation

// What an app needs of the glyphs of a block without seeing them: the look of the first visible one, which is how Windows
// shows text being typed over a line, and how far the block's own scaling is from page units, which a size change needs.

/// The font, the size and the colour a glyph is drawn with. `userSize` is in page units; `fontSize` is what `Tf` was given.
public struct GlyphLook {
    public let font: PdfFont
    public let userSize: Double
    public let fontSize: Double
    public let color: RgbColor
}

extension PageEditor {
    /// The look of the first glyph in `range` that is not a space; nil when there is none.
    public func look(of range: TextRange) throws -> GlyphLook? {
        Self.look(try model.glyphsIn(range), orFirst: false)
    }

    /// The look of the first visible glyph of a block, else of its first glyph.
    public func look(of block: TextObject) -> GlyphLook? {
        Self.look(block.glyphs, orFirst: true)
    }

    private static func look(_ glyphs: [EditGlyph], orFirst: Bool) -> GlyphLook? {
        let visible = glyphs.first { $0.text.contains { !$0.isWhitespace } }
        guard let glyph = visible ?? (orFirst ? glyphs.first : nil) else { return nil }
        return GlyphLook(font: glyph.font, userSize: glyph.userSize, fontSize: glyph.fontSize, color: glyph.color)
    }
}
