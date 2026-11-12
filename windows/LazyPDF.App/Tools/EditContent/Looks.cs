using System.Windows.Media;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.EditContent;

/// <summary>How the text being typed looks on the page: the font of the run it replaces as near as Windows has it.</summary>
internal sealed record EditorLook(FontFamily Family, double Size, Color Color, bool Bold, bool Italic, TextAlignment Alignment)
{
    public static EditorLook Of(TextObject text) => new(
        FamilyOf(text.Font), text.Size, Color.FromRgb(text.Color.R, text.Color.G, text.Color.B),
        text.Font?.IsBold ?? false, text.Font?.IsItalic ?? false, text.Alignment);

    /// <summary>The look of one line of the block: its first glyph, not the block's.</summary>
    public static EditorLook Of(TextObject text, IReadOnlyList<EditGlyph> line) =>
        line.FirstOrDefault(g => g.Text.Any(c => !char.IsWhiteSpace(c))) is { } glyph
            ? new(FamilyOf(glyph.Font), glyph.UserSize, Color.FromRgb(glyph.Color.R, glyph.Color.G, glyph.Color.B), glyph.Font.IsBold, glyph.Font.IsItalic, text.Alignment)
            : Of(text);

    public static FontFamily FamilyOf(PdfFont? font) =>
        Installed(font) ?? new FontFamily(font is null ? "Arial" : font.IsFixedPitch ? "Courier New" : font.IsSerif ? "Times New Roman" : "Arial");

    /// <summary>The name shown for a font: the installed family it belongs to, else its own name.</summary>
    public static string NameOf(PdfFont? font) => Installed(font)?.Source ?? font?.Name ?? "";

    // The family whose name starts the font's name: "Arial-BoldMT" is Arial.
    private static FontFamily? Installed(PdfFont? font)
    {
        string name = Squash(font?.Name ?? "");
        return Fonts.SystemFontFamilies
            .Where(f => Squash(f.Source).Length > 2 && name.StartsWith(Squash(f.Source), StringComparison.Ordinal))
            .OrderByDescending(f => f.Source.Length)
            .FirstOrDefault();
    }

    private static string Squash(string name) => new([.. name.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant)]);
}

/// <summary>The colours offered for text and shapes.</summary>
internal static class Palette
{
    public static IReadOnlyList<(string Name, RgbColor Color)> Colors { get; } =
    [
        (Loc.T("Black"), new RgbColor(0, 0, 0)),
        (Loc.T("Gray"), new RgbColor(110, 110, 110)),
        (Loc.T("White"), new RgbColor(255, 255, 255)),
        (Loc.T("Red"), new RgbColor(200, 30, 30)),
        (Loc.T("Orange"), new RgbColor(235, 125, 20)),
        (Loc.T("Yellow"), new RgbColor(240, 200, 20)),
        (Loc.T("Green"), new RgbColor(40, 150, 60)),
        (Loc.T("Blue"), new RgbColor(25, 100, 200)),
        (Loc.T("Purple"), new RgbColor(130, 60, 170)),
    ];

    public static Color Brush(RgbColor c) => Color.FromRgb(c.R, c.G, c.B);
}
