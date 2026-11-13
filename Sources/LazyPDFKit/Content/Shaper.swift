// Twin of windows/LazyPDF.Core/Content/IShaper.cs and CmapShaper.cs.

/// One glyph of a shaped run. `advance` and the offsets are in 1/1000 em (y up); `cluster` is the UTF-16 index in the
/// run text of the first character the glyph stands for.
public struct ShapedGlyph: Equatable {
    public var glyph: Int
    public var advance: Double
    public var xOffset: Double
    public var yOffset: Double
    public var cluster: Int

    public init(glyph: Int, advance: Double, xOffset: Double, yOffset: Double, cluster: Int) {
        self.glyph = glyph
        self.advance = advance
        self.xOffset = xOffset
        self.yOffset = yOffset
        self.cluster = cluster
    }
}

/// Turns a run of text in one direction into positioned glyphs. The apps supply one, as they do the `FontSource`.
public protocol Shaper: AnyObject {
    /// The glyphs of `text` in the font file, left to right as they are drawn, so a right-to-left run comes back
    /// reversed. The text is one run of a single direction and script. Nil when the font cannot be shaped.
    func shape(_ text: String, _ font: FontFile, rightToLeft: Bool, language: String?) -> [ShapedGlyph]?
}

/// The shaper the engine uses when an app gives none: one glyph per code point from the cmap, no substitution and no
/// positioning. Right for Hebrew and Latin; Arabic letters stay in their isolated forms.
public final class CmapShaper: Shaper {
    private var file: FontFile?
    private var parsed: TrueTypeFont?

    public init() {}

    public func shape(_ text: String, _ font: FontFile, rightToLeft: Bool, language: String?) -> [ShapedGlyph]? {
        if file == nil || file!.collectionIndex != font.collectionIndex || file!.data != font.data {
            parsed = TrueTypeFont.tryParse(font.data, font.collectionIndex)
            file = font
        }
        guard let parsed else { return nil }
        return Self.shape(parsed, Array(text.utf16), rightToLeft)
    }

    static func shape(_ font: TrueTypeFont, _ text: [UInt16], _ rightToLeft: Bool) -> [ShapedGlyph] {
        // A mark stays after its base when the run is turned around, so the mark's own overhang lands on the base.
        var groups: [[ShapedGlyph]] = []
        for rune in Utf16Rune.all(text) {
            if isInvisible(rune.value) { continue }
            var gid = font.glyphForCodePoint(rune.value)
            if gid >= font.glyphCount { gid = 0 }
            let glyph = ShapedGlyph(glyph: gid, advance: Double(font.getAdvance(gid)) * 1000.0 / Double(font.unitsPerEm), xOffset: 0, yOffset: 0, cluster: rune.at)
            if !groups.isEmpty && BidiData.typeOf(rune.value) == .nsm {
                groups[groups.count - 1].append(glyph)
            } else {
                groups.append([glyph])
            }
        }
        if rightToLeft { groups.reverse() }
        return groups.flatMap { $0 }
    }

    // Marks and joiners that carry direction or joining only; the cmap has no glyph for them.
    static func isInvisible(_ cp: Int) -> Bool {
        (cp >= 0x200B && cp <= 0x200F) || (cp >= 0x202A && cp <= 0x202E) || (cp >= 0x2060 && cp <= 0x2064)
            || (cp >= 0x2066 && cp <= 0x2069) || cp == 0x061C || cp == 0xFEFF
    }
}
