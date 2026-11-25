namespace LazyPDF.Core;

/// <summary>
/// One glyph of a shaped run. <paramref name="Advance"/> and the offsets are in 1/1000 em (y up);
/// <paramref name="Cluster"/> is the UTF-16 index in the run text of the first character the glyph stands for.
/// </summary>
public readonly record struct ShapedGlyph(int Glyph, double Advance, double XOffset, double YOffset, int Cluster);

/// <summary>Turns a run of text in one direction into positioned glyphs. The apps supply one, as they do the <see cref="IFontSource"/>.</summary>
public interface IShaper
{
    /// <summary>
    /// The glyphs of <paramref name="text"/> in the font file, left to right as they are drawn, so a right-to-left run
    /// comes back reversed. The text is one run of a single direction and script. Null when the font cannot be shaped.
    /// </summary>
    IReadOnlyList<ShapedGlyph>? Shape(string text, FontFile font, bool rightToLeft, string? language);
}
