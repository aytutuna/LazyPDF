using System.Windows.Media;
using LazyPDF.Core;
using FontWeights = System.Windows.FontWeights;
using FontStretches = System.Windows.FontStretches;

namespace LazyPDF.App.Services;

/// <summary>The fonts installed in Windows, as files Core can embed.</summary>
public sealed class SystemFontSource : IFontSource
{
    // The names a PDF or a person uses for fonts Windows has under another.
    private static readonly Dictionary<string, string> Aliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Helvetica"] = "Arial",
        ["Times"] = "Times New Roman",
        ["Courier"] = "Courier New",
        ["Symbol"] = "Symbol",
    };

    public FontFile? Find(string family, FontStyles style)
    {
        string name = Aliases.GetValueOrDefault(family, family);
        var match = Fonts.SystemFontFamilies.FirstOrDefault(f => f.FamilyNames.Values.Any(n => string.Equals(n, name, StringComparison.OrdinalIgnoreCase)));
        if (match is null) return null;
        var typeface = new Typeface(match,
            style.HasFlag(FontStyles.Italic) ? System.Windows.FontStyles.Italic : System.Windows.FontStyles.Normal,
            style.HasFlag(FontStyles.Bold) ? FontWeights.Bold : FontWeights.Normal,
            FontStretches.Normal);
        if (!typeface.TryGetGlyphTypeface(out var glyphs) || glyphs.FontUri is not { IsFile: true } uri) return null;
        try
        {
            // A .ttc names the face it wants after the file name's number sign.
            int index = int.TryParse(uri.Fragment.TrimStart('#'), out int found) ? found : 0;
            return new FontFile(File.ReadAllBytes(uri.LocalPath), index);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
