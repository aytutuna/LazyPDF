using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// What a font already in the file can show: the bytes and width of each character it has a glyph
/// for, read back from its encoding or CMap. A font cut down to a subset has glyphs for the
/// characters the file uses and no more; a composite font whose program is whole (no subset tag, a
/// TrueType program with the identity mapping) can also take characters through its own cmap.
/// </summary>
internal sealed class FontCodec(PdfDocument document, PdfFont font)
{
    private Dictionary<string, FontCode>? _codes;
    private readonly Dictionary<int, (string Text, double Width)> _added = [];

    public PdfFont Font { get; } = font;

    public bool HasAdditions => _added.Count > 0;

    public bool TryGet(string text, out FontCode code)
    {
        _codes ??= Scan();
        return _codes.TryGetValue(text, out code);
    }

    /// <summary>The code and width for a character of the embedded program that no code of the file's font reaches; false when the font is cut down or not a font this can extend.</summary>
    public bool TryExtend(string text, out FontCode code)
    {
        code = default;
        if (text.Length == 0 || !CanExtend(out var tt)) return false;
        int codePoint = char.ConvertToUtf32(text, 0);
        if (text.Length != char.ConvertFromUtf32(codePoint).Length) return false;
        int gid = tt.GlyphForCodePoint(codePoint);
        if (gid <= 0 || gid > 0xFFFF || (tt.GetBounds(gid) is null && !char.IsWhiteSpace(text[0]))) return false;
        double width = Math.Round(tt.GetAdvance(gid) * 1000.0 / tt.UnitsPerEm, 3);
        code = new FontCode([(byte)(gid >> 8), (byte)gid], width, false);
        _added[gid] = (text, width);
        _codes ??= Scan();
        _codes[text] = code;
        return true;
    }

    private bool CanExtend(out TrueTypeFont tt)
    {
        tt = null!;
        if (!Font.IsComposite || Font.Name != Font.BaseFont || Font.Program?.TrueType is not { Cff: null } program) return false;
        if (document.Name(Font.Dictionary, "Encoding") != "Identity-H") return false;
        if (document.Array(Font.Dictionary, "DescendantFonts")?.Items.FirstOrDefault() is not { } first || document.Resolve(first) is not PdfDictionary descendant) return false;
        if (document.Name(descendant, "Subtype") != "CIDFontType2") return false;
        var map = document.Resolve(descendant["CIDToGIDMap"]);
        if (map is not null && map is not PdfName { Value: "Identity" }) return false;
        tt = program;
        return true;
    }

    /// <summary>Writes the widths and text of the characters taken from the program into the font dictionary.</summary>
    public void WriteAdditions()
    {
        if (_added.Count == 0) return;
        var descendant = (PdfDictionary)document.Resolve(document.Array(Font.Dictionary, "DescendantFonts")!.Items[0])!;
        var widths = document.Resolve(descendant["W"]) as PdfArray;
        if (widths is null) descendant["W"] = widths = new PdfArray([]);
        foreach (var (gid, entry) in _added.OrderBy(a => a.Key))
        {
            widths.Items.Add(new PdfNumber(gid));
            widths.Items.Add(new PdfArray([new PdfNumber(entry.Width)]));
        }
        if (document.Stream(Font.Dictionary, "ToUnicode") is not { } map) return;
        byte[] data;
        try
        {
            data = document.Data(map, 16 << 20);
        }
        catch (PdfReadException)
        {
            return;
        }
        string cmap = Encoding.Latin1.GetString(data);
        int end = cmap.LastIndexOf("endcmap", StringComparison.Ordinal);
        if (end < 0) return;
        var section = new StringBuilder();
        foreach (var chunk in _added.OrderBy(a => a.Key).Chunk(100))
        {
            section.Append(chunk.Length).Append(" beginbfchar\n");
            foreach (var (gid, entry) in chunk)
            {
                section.Append($"<{gid:X4}> <{Convert.ToHexString(Encoding.BigEndianUnicode.GetBytes(entry.Text))}>\n");
            }
            section.Append("endbfchar\n");
        }
        map.Dictionary["Filter"] = new PdfName("FlateDecode");
        map.Dictionary.Remove("DecodeParms");
        map.Data = PdfFilterEncoders.Flate(Encoding.Latin1.GetBytes(cmap.Insert(end, section.ToString())));
    }

    private CMap? ToUnicode()
    {
        try
        {
            return document.Stream(Font.Dictionary, "ToUnicode") is { } stream ? CMap.Parse(document.Data(stream, 16 << 20)) : null;
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    private Dictionary<string, FontCode> Scan()
    {
        var codes = new Dictionary<string, FontCode>();
        // A whole program reaches glyphs the file never mentions; those have no width or text entry yet and go through TryExtend.
        var mapped = CanExtend(out _) ? ToUnicode() : null;
        void Add(in FontChar ch)
        {
            if (string.IsNullOrEmpty(ch.Unicode) || ch.Unicode.Any(char.IsControl)) return;
            if (mapped is not null && mapped.UnicodeOf(ch.Code, ch.Length) is not { Length: > 0 }) return;
            bool blank = ch.Unicode.All(char.IsWhiteSpace);
            if (ch.Width <= 0 && !blank) return;
            if (!Font.CanDraw(in ch)) return;
            var bytes = new byte[ch.Length];
            for (int i = 0; i < bytes.Length; i++) bytes[i] = (byte)(ch.Code >> 8 * (bytes.Length - 1 - i));
            codes.TryAdd(ch.Unicode, new FontCode(bytes, ch.Width, ch.IsSpace));
        }
        if (!Font.IsComposite)
        {
            for (int c = 0; c < 256; c++)
            {
                Font.Read([(byte)c], out var ch);
                Add(in ch);
            }
            return codes;
        }
        Span<byte> buffer = stackalloc byte[4];
        for (int hi = 0; hi < 256; hi++)
        {
            buffer.Clear();
            buffer[0] = (byte)hi;
            int used = Font.Read(buffer, out var ch);
            if (used == 1)
            {
                Add(in ch);
                continue;
            }
            if (used != 2) continue;
            for (int lo = 0; lo < 256; lo++)
            {
                buffer[1] = (byte)lo;
                if (Font.Read(buffer, out ch) == 2) Add(in ch);
            }
        }
        return codes;
    }
}

/// <summary>The bytes a character is shown with, its width in 1/1000 em, and whether word spacing applies to it.</summary>
internal readonly record struct FontCode(byte[] Bytes, double Width, bool IsSpace);

/// <summary>Picks a system font for characters the file's font cannot show, by the names and flags of the one that is there.</summary>
internal static class FontMatch
{
    /// <summary>Family names to try, best first, and the style.</summary>
    public static (IReadOnlyList<string> Families, FontStyles Style) For(PdfFont font)
    {
        string name = font.Name;
        int cut = name.IndexOfAny(['-', ',']);
        string family = cut > 0 ? name[..cut] : name;
        foreach (string suffix in (ReadOnlySpan<string>)["PSMT", "MT", "PS"])
        {
            if (family.Length > suffix.Length + 2 && family.EndsWith(suffix, StringComparison.Ordinal))
            {
                family = family[..^suffix.Length];
                break;
            }
        }
        string spaced = Split(family);
        var style = (font.IsBold ? FontStyles.Bold : FontStyles.Regular) | (font.IsItalic ? FontStyles.Italic : FontStyles.Regular);
        bool narrow = name.Contains("Narrow", StringComparison.OrdinalIgnoreCase) || name.Contains("Condensed", StringComparison.OrdinalIgnoreCase)
            || name.Contains("Cond", StringComparison.Ordinal);
        var families = new List<string>();
        if (narrow && !spaced.Contains("Narrow")) families.Add(spaced + " Narrow");
        families.Add(spaced);
        families.Add(font.IsFixedPitch ? "Courier New" : font.IsSerif ? "Times New Roman" : "Arial");
        return (families.Distinct().ToList(), style);
    }

    private static string Split(string name)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < name.Length; i++)
        {
            if (i > 0 && char.IsUpper(name[i]) && char.IsLower(name[i - 1])) sb.Append(' ');
            sb.Append(name[i]);
        }
        return sb.ToString();
    }
}
