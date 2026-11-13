using System.Text;

namespace LazyPDF.Core;

[Flags]
public enum FontStyles
{
    Regular = 0,
    Bold = 1,
    Italic = 2,
}

/// <summary>Font file bytes and, for a .ttc collection, which font in it.</summary>
public sealed record FontFile(byte[] Data, int CollectionIndex = 0);

/// <summary>Where the app finds font files; Core reads none itself.</summary>
public interface IFontSource
{
    /// <summary>The file of the closest font to <paramref name="family"/> in <paramref name="style"/>, or null when there is none.</summary>
    FontFile? Find(string family, FontStyles style);
}

/// <summary>
/// Adds fonts to a document for drawing new text. A Standard 14 font is used when the text fits
/// WinAnsi and no font file is wanted; anything else (Turkish ğ, ş, ı among it) is embedded from the
/// file the <see cref="IFontSource"/> gives, as a subset Type0 font with Identity-H, /W and /ToUnicode.
/// Each call adds a font of its own holding just the characters of its texts, so give it all the
/// text it is to draw. The texts are shaped with the <see cref="IShaper"/> (the <see cref="CmapShaper"/> when none is given)
/// and the glyphs it picks are what gets embedded; <paramref name="language"/> is passed on to it.
/// </summary>
public sealed class PdfFontEmbedder(PdfDocument document, IFontSource? source = null, IShaper? shaper = null, string? language = null)
{
    private readonly IShaper _shaper = shaper ?? new CmapShaper();
    private readonly bool _builtIn = shaper is null;

    private static readonly Dictionary<int, int> WinAnsiCodes = BuildWinAnsi();

    private static readonly string[] FallbackFamilies =
        ["Arial", "Segoe UI", "Microsoft YaHei", "Yu Gothic", "Malgun Gothic", "Arial Unicode MS", "PingFang SC", "Hiragino Sans", "Apple SD Gothic Neo"];

    private static readonly string[] HebrewFamilies = ["Segoe UI", "Arial", "Tahoma", "Times New Roman", "Arial Hebrew", "Arial Unicode MS"];
    private static readonly string[] ArabicFamilies = ["Segoe UI", "Tahoma", "Arial", "Times New Roman", "Geeza Pro", "Arial Unicode MS"];

    /// <summary>
    /// A font that can draw <paramref name="texts"/>, or null when none can: no file from the source,
    /// a file that cannot be embedded, or a font file wanted and no source given.
    /// </summary>
    /// <param name="embed">Always embed a font file, even for text a Standard 14 font could draw.</param>
    public PdfDrawFont? Add(string family, FontStyles style, IEnumerable<string> texts, bool embed = false)
    {
        var all = texts.ToList();
        if (!embed && FindStandard(family, style) is { IsSymbolic: false } standard && all.All(Fits))
        {
            var dictionary = new PdfDictionary();
            dictionary["Type"] = new PdfName("Font");
            dictionary["Subtype"] = new PdfName("Type1");
            dictionary["BaseFont"] = new PdfName(standard.Name);
            dictionary["Encoding"] = new PdfName("WinAnsiEncoding");
            return new PdfDrawFont(document.Add(dictionary), standard);
        }
        return Pick(ScriptCandidates(family, all), style, all);
    }

    /// <summary>
    /// Like <see cref="Add"/>, but for text the family has no glyphs for it tries <see cref="FallbackFamilies"/> and
    /// takes the first font that covers all of it, else the one that misses least. One font draws the whole text.
    /// Only the font chosen is added to the document; check <see cref="PdfDrawFont.Missing"/> on it.
    /// </summary>
    public PdfDrawFont? AddCovering(string family, FontStyles style, IEnumerable<string> texts)
    {
        var all = texts.ToList();
        // Text that fits WinAnsi needs no fallback; null lets the caller's Helvetica retry run.
        if (all.All(Fits)) return Add(family, style, all);
        return Pick(ScriptCandidates(family, all).Concat(FallbackFamilies).Distinct(StringComparer.OrdinalIgnoreCase), style, all);
    }

    // The family asked for, then the fonts that carry the Hebrew or Arabic the texts hold.
    private static IEnumerable<string> ScriptCandidates(string family, List<string> texts)
    {
        var names = new List<string> { family };
        if (Scripts.HasArabic(texts)) names.AddRange(ArabicFamilies);
        if (Scripts.HasHebrew(texts)) names.AddRange(HebrewFamilies);
        return names.Distinct(StringComparer.OrdinalIgnoreCase);
    }

    private PdfDrawFont? Pick(IEnumerable<string> families, FontStyles style, List<string> texts)
    {
        (EmbeddedFont Built, TrueTypeFont Measure, LineShaper Lines)? best = null;
        foreach (string name in families)
        {
            if (source?.Find(name, style) is not { } file || Try(file, texts) is not { } found) continue;
            if (best is null || found.Built.Missing.Count < best.Value.Built.Missing.Count) best = found;
            if (found.Built.Missing.Count == 0) break;
        }
        return best is { } chosen ? new PdfDrawFont(AddType0(chosen.Built), chosen.Built, chosen.Measure, chosen.Lines, _builtIn) : null;
    }

    private (EmbeddedFont Built, TrueTypeFont Measure, LineShaper Lines)? Try(FontFile file, List<string> texts)
    {
        if (TrueTypeFont.TryParse(file.Data, file.CollectionIndex) is not { } measure) return null;
        var lines = new LineShaper(file, _shaper, measure, language);
        var unicodeOf = new Dictionary<int, string>();
        var missing = new SortedSet<int>();
        foreach (string text in texts)
        {
            foreach (string paragraph in text.ReplaceLineEndings("\n").Split('\n'))
            {
                if (_builtIn && !Scripts.NeedsBidi(paragraph)) CollectPlain(paragraph, measure, unicodeOf, missing);
                else
                {
                    // The base direction may be set later, which changes which glyphs are mirrored.
                    foreach (int level in (ReadOnlySpan<int>)[BidiParagraph.Auto, 0, 1])
                        Collect(lines.Shape(paragraph, level), unicodeOf, missing);
                }
            }
        }
        var built = EmbeddedFontBuilder.BuildGlyphs(file.Data, unicodeOf, missing, out _, file.CollectionIndex);
        return built is null ? null : (built, measure, lines);
    }

    // Left-to-right text and the built-in shaper: the cmap glyph of each character, and the mirror image of a bracket in case the line is turned around.
    private static void CollectPlain(string paragraph, TrueTypeFont measure, Dictionary<int, string> unicodeOf, SortedSet<int> missing)
    {
        foreach (var rune in paragraph.EnumerateRunes())
        {
            if (rune.Value < 0x20 || CmapShaper.IsInvisible(rune.Value)) continue;
            Note(unicodeOf, missing, measure, rune.Value, rune.ToString());
            int mirror = BidiData.Mirror(rune.Value);
            if (mirror != rune.Value && measure.GlyphForCodePoint(mirror) is var gid && gid > 0 && gid < measure.GlyphCount) unicodeOf.TryAdd(gid, "");
        }
    }

    private static void Note(Dictionary<int, string> unicodeOf, SortedSet<int> missing, TrueTypeFont measure, int cp, string text)
    {
        int gid = measure.GlyphForCodePoint(cp);
        if (gid <= 0 || gid >= measure.GlyphCount) missing.Add(cp);
        else Keep(unicodeOf, gid, text);
    }

    // Where two texts share a glyph the lower one wins, as in the cmap path.
    private static void Keep(Dictionary<int, string> unicodeOf, int gid, string text)
    {
        if (!unicodeOf.TryGetValue(gid, out string? known) || known.Length == 0 || (text.Length > 0 && string.CompareOrdinal(text, known) < 0))
            unicodeOf[gid] = text;
    }

    // The first glyph of a cluster gets the cluster's text; the others of a one-to-many cluster, and mirrored ones, stand for nothing of their own.
    private static void Collect(ShapedLine line, Dictionary<int, string> unicodeOf, SortedSet<int> missing)
    {
        var seen = new HashSet<(int, int)>();
        foreach (var glyph in line.Glyphs)
        {
            string text = string.Concat(line.Text[glyph.Start..glyph.End].EnumerateRunes().Where(r => !CmapShaper.IsInvisible(r.Value)).Select(r => r.ToString()));
            if (glyph.Shaped.Glyph <= 0)
            {
                foreach (var rune in text.EnumerateRunes()) missing.Add(rune.Value);
                continue;
            }
            if (glyph.Mirrored || !seen.Add((glyph.Start, glyph.End))) text = "";
            Keep(unicodeOf, glyph.Shaped.Glyph, text);
        }
    }

    private static Standard14? FindStandard(string family, FontStyles style)
    {
        string bold = style.HasFlag(FontStyles.Bold) ? "Bold" : "";
        foreach (string italic in style.HasFlag(FontStyles.Italic) ? (ReadOnlySpan<string>)["Italic", "Oblique"] : [""])
        {
            string suffix = bold + italic;
            if (Standard14.Find(suffix.Length == 0 ? family : $"{family}-{suffix}") is { } found) return found;
        }
        return null;
    }

    private static bool Fits(string text) => text.EnumerateRunes().All(r => r.Value < 0x20 || WinAnsiCodes.ContainsKey(r.Value));

    private static Dictionary<int, int> BuildWinAnsi()
    {
        var map = new Dictionary<int, int>();
        var table = PdfEncodings.WinAnsi;
        for (int code = 32; code < 256; code++)
        {
            // The unused codes read as bullet in the table and must not claim it.
            if (code is 127 or 129 or 141 or 143 or 144 or 157) continue;
            if (table[code] is { } name && GlyphList.UnicodeOf(name) is { Length: > 0 } text) map.TryAdd(char.ConvertToUtf32(text, 0), code);
        }
        // Codes 160 and 173 show the space and hyphen glyphs, so the names alone never reach these.
        map.TryAdd(0xA0, 160);
        map.TryAdd(0xAD, 173);
        return map;
    }

    internal static int WinAnsiCode(int codePoint) => WinAnsiCodes.GetValueOrDefault(codePoint, '?');

    private PdfReference AddType0(EmbeddedFont font)
    {
        var fontFile = new PdfDictionary();
        fontFile["Length1"] = new PdfNumber(font.Program.Length);
        if (font.IsCff) fontFile["Subtype"] = new PdfName("OpenType");
        var file = document.Add(Flate(fontFile, font.Program));

        var d = font.Descriptor;
        var descriptor = new PdfDictionary();
        descriptor["Type"] = new PdfName("FontDescriptor");
        descriptor["FontName"] = new PdfName(font.BaseFont);
        descriptor["Flags"] = new PdfNumber(d.Flags);
        descriptor["FontBBox"] = new PdfArray([.. d.FontBBox.Select(n => (PdfObject)new PdfNumber(n))]);
        descriptor["ItalicAngle"] = new PdfNumber(d.ItalicAngle);
        descriptor["Ascent"] = new PdfNumber(d.Ascent);
        descriptor["Descent"] = new PdfNumber(d.Descent);
        descriptor["CapHeight"] = new PdfNumber(d.CapHeight);
        descriptor["StemV"] = new PdfNumber(d.StemV);
        descriptor[font.IsCff ? "FontFile3" : "FontFile2"] = file;

        var widths = new List<PdfObject>();
        foreach (var run in font.Widths)
        {
            widths.Add(new PdfNumber(run.FirstCid));
            widths.Add(new PdfArray([.. run.Widths.Select(w => (PdfObject)new PdfNumber(w))]));
        }
        var info = new PdfDictionary();
        info["Registry"] = new PdfString("Adobe"u8.ToArray(), isHex: false);
        info["Ordering"] = new PdfString("Identity"u8.ToArray(), isHex: false);
        info["Supplement"] = new PdfNumber(0L);
        var cid = new PdfDictionary();
        cid["Type"] = new PdfName("Font");
        cid["Subtype"] = new PdfName(font.IsCff ? "CIDFontType0" : "CIDFontType2");
        cid["BaseFont"] = new PdfName(font.BaseFont);
        cid["CIDSystemInfo"] = info;
        cid["FontDescriptor"] = document.Add(descriptor);
        cid["DW"] = new PdfNumber(font.DefaultWidth);
        cid["W"] = new PdfArray(widths);
        if (!font.IsCff) cid["CIDToGIDMap"] = new PdfName("Identity");

        var toUnicode = document.Add(Flate(new PdfDictionary(), ToUnicodeCMap.Write(font.UnicodeOfCode)));

        var type0 = new PdfDictionary();
        type0["Type"] = new PdfName("Font");
        type0["Subtype"] = new PdfName("Type0");
        type0["BaseFont"] = new PdfName(font.BaseFont);
        type0["Encoding"] = new PdfName("Identity-H");
        type0["DescendantFonts"] = new PdfArray([document.Add(cid)]);
        type0["ToUnicode"] = toUnicode;
        return document.Add(type0);
    }

    private static PdfStream Flate(PdfDictionary dictionary, byte[] data)
    {
        dictionary["Filter"] = new PdfName("FlateDecode");
        return new PdfStream(dictionary, PdfFilterEncoders.Flate(data));
    }
}

/// <summary>
/// A font added by <see cref="PdfFontEmbedder"/>: its reference for a /Font resource, the encoding of
/// text for <c>Tj</c>, and measurements for laying text out.
/// </summary>
public sealed class PdfDrawFont
{
    private readonly Standard14? _standard;
    private readonly EmbeddedFont? _embedded;
    private readonly TrueTypeFont? _measure;
    private readonly LineShaper? _lines;
    private readonly bool _plain;

    internal PdfDrawFont(PdfReference reference, Standard14 standard)
    {
        Reference = reference;
        _standard = standard;
        Ascent = standard.Ascent / 1000.0;
        Descent = standard.Descent / 1000.0;
    }

    // plain: the built-in shaper draws it, so text without right-to-left characters needs neither bidi nor shaping.
    internal PdfDrawFont(PdfReference reference, EmbeddedFont embedded, TrueTypeFont measure, LineShaper lines, bool plain)
    {
        Reference = reference;
        _embedded = embedded;
        _measure = measure;
        _lines = lines;
        _plain = plain;
        Ascent = embedded.Descriptor.Ascent / 1000.0;
        Descent = embedded.Descriptor.Descent / 1000.0;
    }

    /// <summary>The font object, to put in a /Font resource.</summary>
    public PdfReference Reference { get; }

    public bool IsEmbedded => _embedded is not null;

    /// <summary>Code points of the text the font has no glyph for; they draw as .notdef.</summary>
    public IReadOnlyList<int> Missing => _embedded?.Missing ?? [];

    /// <summary>In em; the descent is negative.</summary>
    public double Ascent { get; }
    public double Descent { get; }

    public double LineHeight(double size) => (Ascent - Descent) * size * 1.15;

    /// <summary>
    /// The string as the bytes a <c>Tj</c> shows: one byte a character, or two a glyph for an embedded font. Text with
    /// right-to-left characters comes out in display order, shaped; the line's own first strong character sets the base direction.
    /// </summary>
    public byte[] Encode(string text)
    {
        if (_embedded is not null)
        {
            if (Shaped(text) is not { } line) return EncodePlain(text);
            var bytes = new byte[line.Glyphs.Count * 2];
            for (int i = 0; i < line.Glyphs.Count; i++)
            {
                int code = _embedded.GlyphCodes.GetValueOrDefault(line.Glyphs[i].Shaped.Glyph);
                bytes[2 * i] = (byte)(code >> 8);
                bytes[2 * i + 1] = (byte)code;
            }
            return bytes;
        }
        return [.. text.EnumerateRunes().Where(r => r.Value >= 0x20).Select(r => (byte)PdfFontEmbedder.WinAnsiCode(r.Value))];
    }

    /// <summary>The width of the text set in <paramref name="size"/> points, kerning not applied.</summary>
    public double Width(string text, double size)
    {
        if (Shaped(text) is { } line) return line.Width * size / 1000;
        double units = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value >= 0x20 && !(_embedded is not null && CmapShaper.IsInvisible(rune.Value))) units += Advance(rune.Value);
        }
        return units * size / 1000;
    }

    // One glyph a character from the cmap. Joiners take no space, as with the shaper.
    private byte[] EncodePlain(string text)
    {
        var bytes = new List<byte>(text.Length * 2);
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value < 0x20 || CmapShaper.IsInvisible(rune.Value)) continue;
            int gid = _measure!.GlyphForCodePoint(rune.Value);
            int code = gid < _measure.GlyphCount ? _embedded!.GlyphCodes.GetValueOrDefault(gid) : 0;
            bytes.Add((byte)(code >> 8));
            bytes.Add((byte)code);
        }
        return [.. bytes];
    }

    /// <summary>The line shaped and in display order; null when the font is not embedded or the text is plain and needs no shaping.</summary>
    internal ShapedLine? Shaped(string text, int baseLevel = BidiParagraph.Auto) =>
        _lines is null || (_plain && baseLevel != 1 && !Scripts.NeedsBidi(text)) ? null : _lines.Shape(text, baseLevel);

    /// <summary>The width in 1/1000 em that /W gives the code; a shaped advance that differs is made up in the <c>TJ</c> adjustments.</summary>
    internal double CodeWidth(int glyph) => _measure is null ? 0 : Math.Round(_measure.GetAdvance(glyph) * 1000.0 / _measure.UnitsPerEm);

    /// <summary>The character code of a glyph of the shaped text.</summary>
    internal byte[] CodeOf(int glyph)
    {
        int code = _embedded?.GlyphCodes.GetValueOrDefault(glyph) ?? 0;
        return [(byte)(code >> 8), (byte)code];
    }

    private double Advance(int codePoint)
    {
        if (_measure is not null) return _measure.GetAdvance(_measure.GlyphForCodePoint(codePoint)) * 1000.0 / _measure.UnitsPerEm;
        int code = PdfFontEmbedder.WinAnsiCode(codePoint);
        return PdfEncodings.WinAnsi[code] is { } name ? _standard!.WidthOf(name) ?? 0 : 0;
    }

    /// <summary>
    /// Breaks the text into lines no wider than <paramref name="maxWidth"/>: at spaces, a word wider
    /// than the box at the character, and at every newline. A line keeps no trailing space. Lines are broken on the
    /// logical text. When a line would start in another direction than its paragraph, which is the first strong
    /// character's unless <paramref name="rightToLeft"/> says, it gets a direction mark in front so that it
    /// is laid out the paragraph's way.
    /// </summary>
    public IReadOnlyList<string> Wrap(string text, double size, double maxWidth, bool? rightToLeft = null)
    {
        var lines = new List<string>();
        foreach (string paragraph in text.ReplaceLineEndings("\n").Split('\n'))
        {
            int first = lines.Count;
            var line = new StringBuilder();
            foreach (string word in paragraph.Split(' '))
            {
                string joined = line.Length == 0 ? word : line + " " + word;
                if (Width(joined, size) <= maxWidth)
                {
                    line.Clear().Append(joined);
                    continue;
                }
                if (line.Length > 0)
                {
                    lines.Add(line.ToString().TrimEnd());
                    line.Clear();
                }
                foreach (var rune in word.EnumerateRunes())
                {
                    string next = line + rune.ToString();
                    if (line.Length > 0 && Width(next, size) > maxWidth)
                    {
                        lines.Add(line.ToString());
                        line.Clear();
                    }
                    line.Append(rune.ToString());
                }
            }
            lines.Add(line.ToString().TrimEnd());
            if (IsEmbedded && (rightToLeft is not null || Scripts.NeedsBidi(paragraph))) Direct(lines, first, rightToLeft ?? IsRightToLeft(paragraph));
        }
        return lines;
    }

    private void Direct(List<string> lines, int first, bool rightToLeft)
    {
        for (int i = first; i < lines.Count; i++)
        {
            if (IsRightToLeft(lines[i]) != rightToLeft) lines[i] = (rightToLeft ? '‏' : '‎') + lines[i];
        }
    }

    /// <summary>Whether the first strong character of the text is right to left, which makes it a right-to-left paragraph.</summary>
    public bool IsRightToLeft(string text) => Scripts.NeedsBidi(text) && new BidiParagraph(text).Level == 1;
}
