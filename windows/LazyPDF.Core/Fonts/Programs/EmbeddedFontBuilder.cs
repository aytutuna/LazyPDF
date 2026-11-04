using System.Security.Cryptography;
using System.Text;

namespace LazyPDF.Core;

public enum EmbedStatus
{
    Ok,
    Unreadable,
    NoOutlines,
    /// <summary>OS/2 fsType restricts embedding. Nothing is built.</summary>
    EmbeddingForbidden,
}

/// <summary>Widths of consecutive CIDs starting at <paramref name="FirstCid"/>, in 1/1000 em: one "c [w1 w2 ...]" entry of /W.</summary>
public sealed record WidthRun(int FirstCid, IReadOnlyList<int> Widths);

/// <summary>Values for a /FontDescriptor, in the 1/1000 em units of the PDF.</summary>
public sealed record FontDescriptorValues(int Flags, int[] FontBBox, double ItalicAngle, int Ascent, int Descent, int CapHeight, int StemV);

/// <summary>
/// The pieces of a Type0 font with Identity-H encoding (ISO 32000-1 9.7) for some text. Plain data; the caller
/// writes the objects. A character code is two bytes, big-endian, and is also the CID.
/// </summary>
/// <param name="BaseFont">/BaseFont and /FontName, with a six-letter subset tag when <paramref name="IsSubset"/> (9.6.4).</param>
/// <param name="IsCff">False: /CIDFontType2 with the program as /FontFile2 and /CIDToGIDMap /Identity.
/// True: /CIDFontType0 with the whole OpenType font as /FontFile3 /Subtype /OpenType; no CIDToGIDMap.</param>
/// <param name="Program">The font file bytes.</param>
/// <param name="DefaultWidth">/DW. Every code in <paramref name="Widths"/> has its own entry.</param>
/// <param name="Codes">Unicode code point to character code for every character of the text the font has a glyph for.</param>
/// <param name="Missing">Code points of the text the font has no glyph for; they encode as code 0 (.notdef).</param>
public sealed record EmbeddedFont(
    string BaseFont,
    bool IsCff,
    bool IsSubset,
    byte[] Program,
    int DefaultWidth,
    IReadOnlyList<WidthRun> Widths,
    FontDescriptorValues Descriptor,
    IReadOnlyDictionary<int, int> Codes,
    IReadOnlyList<int> Missing)
{
    /// <summary>The string as two-byte codes for a show-text operator.</summary>
    public byte[] Encode(string text)
    {
        var bytes = new List<byte>(text.Length * 2);
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value < 0x20) continue;
            var code = Codes.GetValueOrDefault(rune.Value);
            bytes.Add((byte)(code >> 8));
            bytes.Add((byte)code);
        }
        return bytes.ToArray();
    }

    /// <summary>Character code to code point, for a /ToUnicode CMap. Where two characters share a glyph the lower code point wins.</summary>
    public IReadOnlyDictionary<int, int> ToUnicode()
    {
        var map = new Dictionary<int, int>(Codes.Count);
        foreach (var (codePoint, code) in Codes.OrderByDescending(c => c.Key))
            map[code] = codePoint;
        return map;
    }
}

/// <summary>Builds the font pieces for text from a font file.</summary>
public static class EmbeddedFontBuilder
{
    /// <summary>
    /// TrueType fonts are cut down to the glyphs of <paramref name="texts"/> (<see cref="TrueTypeSubsetter"/>), codes are
    /// the new glyph IDs. A TrueType font whose OS/2 forbids subsetting, and any OpenType font with CFF outlines, is
    /// embedded whole with the glyph ID as code; there is no CFF subsetter. A font that forbids embedding is refused.
    /// </summary>
    public static EmbeddedFont? Build(byte[] font, IEnumerable<string> texts, out EmbedStatus status, int collectionIndex = 0)
    {
        status = EmbedStatus.Unreadable;
        if (TrueTypeFont.TryParse(font, collectionIndex) is not { } f) return null;
        if (!f.HasOutlines)
        {
            status = EmbedStatus.NoOutlines;
            return null;
        }
        if (!f.EmbeddingAllowed)
        {
            status = EmbedStatus.EmbeddingForbidden;
            return null;
        }

        var glyphOf = new SortedDictionary<int, int>();
        var missing = new SortedSet<int>();
        foreach (var text in texts)
            foreach (var rune in text.EnumerateRunes())
            {
                if (rune.Value < 0x20 || glyphOf.ContainsKey(rune.Value) || missing.Contains(rune.Value)) continue;
                var gid = f.GlyphForCodePoint(rune.Value);
                if (gid == 0 || gid >= f.GlyphCount) missing.Add(rune.Value);
                else glyphOf[rune.Value] = gid;
            }

        // A collection cannot be embedded as it is: its fonts share tables by offset.
        var whole = f.IsCff || !f.SubsettingAllowed;
        if (whole && font.AsSpan(0, 4).SequenceEqual("ttcf"u8)) return null;

        byte[] program;
        Dictionary<int, int> codes;
        if (whole)
        {
            program = font;
            // 9.7.4.2: the code of a CIDFontType0 is a CID, which a CID-keyed font maps through its charset.
            codes = f.Cff is { } cff ? glyphOf.ToDictionary(p => p.Key, p => cff.CidForGlyph(p.Value)) : new Dictionary<int, int>(glyphOf);
        }
        else
        {
            var result = TrueTypeSubsetter.Subset(font, glyphOf.Values.ToHashSet(), collectionIndex);
            if (result.Status != SubsetStatus.Ok) return null;
            program = result.Data;
            codes = glyphOf.ToDictionary(p => p.Key, p => result.GlyphMap[p.Value]);
        }

        var widths = new SortedDictionary<int, int>();
        foreach (var (cp, code) in codes)
            widths[code] = Scale(f.GetAdvance(glyphOf[cp]), f.UnitsPerEm);

        // CID 0 has no glyph of the text, but Width measures a missing character by the .notdef advance.
        if (missing.Count > 0) widths[0] = Scale(f.GetAdvance(0), f.UnitsPerEm);

        status = EmbedStatus.Ok;
        return new EmbeddedFont(
            BaseFontName(f, !whole, glyphOf.Values),
            f.IsCff,
            !whole,
            program,
            1000,
            Runs(widths),
            Describe(f),
            codes,
            missing.ToList());
    }

    private static int Scale(double units, int unitsPerEm) => (int)Math.Round(units * 1000 / unitsPerEm);

    private static List<WidthRun> Runs(SortedDictionary<int, int> widths)
    {
        var runs = new List<WidthRun>();
        List<int>? current = null;
        var first = 0;
        var next = -1;
        foreach (var (code, width) in widths)
        {
            if (current == null || code != next)
            {
                if (current != null) runs.Add(new WidthRun(first, current));
                current = [];
                first = code;
            }
            current.Add(width);
            next = code + 1;
        }
        if (current != null) runs.Add(new WidthRun(first, current));
        return runs;
    }

    private static FontDescriptorValues Describe(TrueTypeFont f)
    {
        var u = f.UnitsPerEm;
        var flags = 32;
        if (f.IsFixedPitch) flags |= 1;
        if (f.ItalicAngle != 0) flags |= 64;
        var weight = f.WeightClass is >= 100 and <= 900 ? f.WeightClass : 400;
        var stemV = (int)(50 + Math.Pow(weight / 65.0, 2));
        var b = f.FontBounds;
        return new FontDescriptorValues(flags,
            [Scale(b.XMin, u), Scale(b.YMin, u), Scale(b.XMax, u), Scale(b.YMax, u)],
            f.ItalicAngle, Scale(f.Ascent, u), Scale(f.Descent, u), Scale(f.CapHeight, u), stemV);
    }

    private static string BaseFontName(TrueTypeFont f, bool subset, IEnumerable<int> glyphs)
    {
        var raw = f.PostScriptName ?? f.FamilyName ?? "Font";
        var name = new StringBuilder();
        foreach (var c in raw)
            if (char.IsAsciiLetterOrDigit(c) || c is '-' or '_') name.Append(c);
        if (name.Length == 0) name.Append("Font");
        if (!subset) return name.ToString();

        var seed = Encoding.UTF8.GetBytes(name + ":" + string.Join(',', glyphs));
        var hash = SHA256.HashData(seed);
        var tag = new char[6];
        for (var i = 0; i < 6; i++) tag[i] = (char)('A' + hash[i] % 26);
        return new string(tag) + "+" + name;
    }
}
