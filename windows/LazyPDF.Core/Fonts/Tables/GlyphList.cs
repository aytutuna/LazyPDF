using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// Glyph names and Unicode, by the Adobe Glyph List specification: the AGL and the ZapfDingbats list,
/// then the rules for suffixes, ligature components and the uniXXXX and uXXXX forms.
/// </summary>
public static class GlyphList
{
    const int MaxNameLength = 256;

    static readonly Lazy<Dictionary<string, string>> Agl = new(() => ReadList(GlyphListData.Agl));
    static readonly Lazy<Dictionary<string, string>> Zapf = new(() => ReadList(GlyphListData.Zapf));
    static readonly Lazy<Dictionary<int, string>> Names = new(BuildNames);
    static readonly Lazy<Dictionary<int, string>> ZapfNames = new(() => Reverse(Zapf.Value, []));

    /// <summary>
    /// The text a glyph name stands for, or null when it stands for none (".notdef", "g123", "cid77").
    /// A suffix after the first period is dropped and "f_i" is the concatenation of "f" and "i".
    /// </summary>
    public static string? UnicodeOf(string glyphName)
    {
        if (glyphName.Length == 0 || glyphName.Length > MaxNameLength)
            return null;
        int dot = glyphName.IndexOf('.');
        string name = dot < 0 ? glyphName : glyphName[..dot];
        if (name.Length == 0)
            return null;
        if (name.IndexOf('_') < 0)
            return Component(name);

        var sb = new StringBuilder();
        foreach (var part in name.Split('_'))
            sb.Append(Component(part));
        return sb.Length > 0 ? sb.ToString() : null;
    }

    /// <summary>
    /// A glyph name for the character: the AGL name, preferring the one the standard encodings use
    /// (space, not nbspace), else uniXXXX or uXXXXX. ".notdef" for what is not a Unicode scalar value.
    /// </summary>
    public static string NameOf(int codePoint)
    {
        if (!Rune.IsValid(codePoint))
            return ".notdef";
        if (Names.Value.TryGetValue(codePoint, out var name))
            return name;
        return codePoint <= 0xFFFF
            ? "uni" + codePoint.ToString("X4", CultureInfo.InvariantCulture)
            : "u" + codePoint.ToString("X", CultureInfo.InvariantCulture);
    }

    /// <summary>The ZapfDingbats glyph name ("a1") of the character, or null.</summary>
    public static string? ZapfNameOf(int codePoint) => ZapfNames.Value.GetValueOrDefault(codePoint);

    static string? Component(string name)
    {
        if (name.Length == 0)
            return null;
        if (Agl.Value.TryGetValue(name, out var text) || Zapf.Value.TryGetValue(name, out text))
            return text;
        if (name.StartsWith("uni", StringComparison.Ordinal) && name.Length > 3 && (name.Length - 3) % 4 == 0)
        {
            var sb = new StringBuilder();
            for (int i = 3; i < name.Length; i += 4)
            {
                if (!int.TryParse(name.AsSpan(i, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out int unit)
                    || !Rune.IsValid(unit) || !IsHexRun(name.AsSpan(i, 4)))
                    return null;
                sb.Append((char)unit);
            }
            return sb.ToString();
        }
        if (name[0] == 'u' && name.Length is >= 5 and <= 7 && IsHexRun(name.AsSpan(1))
            && int.TryParse(name.AsSpan(1), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out int scalar)
            && Rune.IsValid(scalar))
            return char.ConvertFromUtf32(scalar);
        return null;
    }

    // The int parser accepts a sign and spaces, a glyph name must not.
    static bool IsHexRun(ReadOnlySpan<char> s)
    {
        foreach (char c in s)
            if (!char.IsAsciiHexDigit(c))
                return false;
        return true;
    }

    static Dictionary<string, string> ReadList(string packed)
    {
        var map = new Dictionary<string, string>(5000, StringComparer.Ordinal);
        foreach (var line in TableBlob.InflateText(packed).Split('\n'))
        {
            var parts = line.Split(' ');
            if (parts.Length < 2)
                continue;
            var sb = new StringBuilder();
            for (int i = 1; i < parts.Length; i++)
                sb.Append(char.ConvertFromUtf32(int.Parse(parts[i], NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture)));
            map.TryAdd(parts[0], sb.ToString());
        }
        return map;
    }

    static Dictionary<int, string> BuildNames()
    {
        var preferred = new HashSet<string>(StringComparer.Ordinal);
        foreach (var table in new[] { PdfEncodings.Standard, PdfEncodings.WinAnsi, PdfEncodings.MacRoman,
                     PdfEncodings.MacExpert, PdfEncodings.PdfDoc, PdfEncodings.Symbol })
            foreach (var name in table)
                if (name != null)
                    preferred.Add(name);
        return Reverse(Agl.Value, preferred);
    }

    // Single-character entries only; a name from preferred wins over the first one in list order.
    static Dictionary<int, string> Reverse(Dictionary<string, string> list, HashSet<string> preferred)
    {
        var map = new Dictionary<int, string>(list.Count);
        foreach (var name in preferred)
            if (list.TryGetValue(name, out var text) && Single(text) is int cp)
                map.TryAdd(cp, name);
        foreach (var (name, text) in list)
            if (Single(text) is int cp)
                map.TryAdd(cp, name);
        return map;
    }

    static int? Single(string text)
    {
        var runes = text.EnumerateRunes();
        if (!runes.MoveNext())
            return null;
        int first = runes.Current.Value;
        return runes.MoveNext() ? null : first;
    }
}
