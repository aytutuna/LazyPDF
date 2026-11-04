namespace LazyPDF.Core;

/// <summary>The embedded font file of a font descriptor, whichever of the three formats it holds.</summary>
internal sealed class FontProgram
{
    private const long MaxSize = 64L << 20;

    private Dictionary<int, int>? _reverse;

    public TrueTypeFont? TrueType { get; private init; }
    public CffFont? BareCff { get; private init; }
    public Type1Font? Type1 { get; private init; }

    /// <summary>The CFF outlines of a bare CFF or an OpenType font.</summary>
    public CffFont? Cff => BareCff ?? TrueType?.Cff;

    public static FontProgram? Load(PdfDocument document, PdfDictionary? descriptor)
    {
        if (descriptor is null) return null;
        foreach (string key in (ReadOnlySpan<string>)["FontFile2", "FontFile3", "FontFile"])
        {
            if (document.Resolve(descriptor[key]) is not PdfStream stream) continue;
            byte[] data;
            try
            {
                data = document.Data(stream, MaxSize);
            }
            catch (PdfReadException)
            {
                continue;
            }
            if (Parse(data) is { } program) return program;
        }
        return null;
    }

    // The key a file sits under is no guide: sniff the bytes.
    private static FontProgram? Parse(byte[] data)
    {
        if (data.Length < 4) return null;
        if (data.AsSpan(0, 4) is [0, 1, 0, 0] or [(byte)'t', (byte)'r', (byte)'u', (byte)'e'] or [(byte)'O', (byte)'T', (byte)'T', (byte)'O'] or [(byte)'t', (byte)'t', (byte)'c', (byte)'f'])
            return TrueTypeFont.TryParse(data) is { } tt ? new FontProgram { TrueType = tt } : null;
        if (data[0] == 1 && data[1] == 0)
            return CffFont.TryParse(data) is { } cff ? new FontProgram { BareCff = cff } : null;
        return Type1Font.TryParse(data) is { } t1 ? new FontProgram { Type1 = t1 } : null;
    }

    /// <summary>The glyph name the program's own encoding gives a code.</summary>
    public string? BuiltInName(int code)
    {
        if (Type1 is not null) return Type1.BuiltInEncoding[code];
        if (Cff is { } cff && cff.GlyphForCode(code) is > 0 and var gid) return cff.GlyphName(gid);
        return null;
    }

    /// <summary>The advance of a glyph in 1/1000 em, by name where the program has names, else by code.</summary>
    public double? Width(int code, string? name)
    {
        if (Type1 is { } t1)
        {
            name ??= t1.BuiltInEncoding[code];
            return name is not null && t1.HasGlyph(name) ? t1.GetWidth(name) * t1.FontMatrix[0] * 1000 : null;
        }
        if (Cff is { } cff && TrueType is null)
        {
            int gid = name is not null ? cff.GlyphForName(name) : 0;
            if (gid == 0) gid = cff.GlyphForCode(code);
            return gid > 0 ? cff.GetWidth(gid) * cff.FontMatrix[0] * 1000 : null;
        }
        return null;
    }

    /// <summary>The text of a TrueType glyph: the cmap read backwards, then the glyph's name in the post table.</summary>
    public string? UnicodeOf(int glyph)
    {
        if (TrueType is not { } tt) return null;
        _reverse ??= ReverseCmap(tt);
        if (_reverse.TryGetValue(glyph, out int codePoint)) return char.ConvertFromUtf32(codePoint);
        return tt.GlyphName(glyph) is { } name ? GlyphList.UnicodeOf(name) : null;
    }

    // The private use area is where symbol fonts park their glyphs; as text it is noise.
    private static Dictionary<int, int> ReverseCmap(TrueTypeFont tt)
    {
        var map = new Dictionary<int, int>();
        for (int cp = 0x20; cp <= 0xFFFF; cp++)
        {
            if (cp is >= 0xD800 and <= 0xF8FF) continue;
            int glyph = tt.GlyphForCodePoint(cp);
            if (glyph > 0) map.TryAdd(glyph, cp);
        }
        return map;
    }
}
