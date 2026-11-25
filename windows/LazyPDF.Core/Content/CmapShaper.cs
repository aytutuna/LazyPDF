namespace LazyPDF.Core;

/// <summary>
/// The shaper Core uses when an app gives none: one glyph per code point from the cmap, no substitution and no
/// positioning. Right for Hebrew and Latin; Arabic letters stay in their isolated forms.
/// </summary>
public sealed class CmapShaper : IShaper
{
    private FontFile? _file;
    private TrueTypeFont? _font;

    public IReadOnlyList<ShapedGlyph>? Shape(string text, FontFile font, bool rightToLeft, string? language)
    {
        if (!ReferenceEquals(_file?.Data, font.Data) || _file?.CollectionIndex != font.CollectionIndex)
        {
            _font = TrueTypeFont.TryParse(font.Data, font.CollectionIndex);
            _file = font;
        }
        return _font is null ? null : Shape(_font, text, rightToLeft);
    }

    internal static List<ShapedGlyph> Shape(TrueTypeFont font, string text, bool rightToLeft)
    {
        // A mark stays after its base when the run is turned around, so the mark's own overhang lands on the base.
        var groups = new List<List<ShapedGlyph>>();
        int index = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            int start = index;
            index += rune.Utf16SequenceLength;
            if (IsInvisible(rune.Value)) continue;
            int gid = font.GlyphForCodePoint(rune.Value);
            if (gid >= font.GlyphCount) gid = 0;
            var glyph = new ShapedGlyph(gid, font.GetAdvance(gid) * 1000.0 / font.UnitsPerEm, 0, 0, start);
            if (groups.Count > 0 && BidiData.TypeOf(rune.Value) == BidiType.NSM) groups[^1].Add(glyph);
            else groups.Add([glyph]);
        }
        if (rightToLeft) groups.Reverse();
        return [.. groups.SelectMany(g => g)];
    }

    // Marks and joiners that carry direction or joining only; the cmap has no glyph for them.
    internal static bool IsInvisible(int cp) =>
        cp is >= 0x200B and <= 0x200F or >= 0x202A and <= 0x202E or >= 0x2060 and <= 0x2064 or >= 0x2066 and <= 0x2069 or 0x061C or 0xFEFF;
}
