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
/// text it is to draw.
/// </summary>
public sealed class PdfFontEmbedder(PdfDocument document, IFontSource? source = null)
{
    private static readonly Dictionary<int, int> WinAnsiCodes = BuildWinAnsi();

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
        if (source?.Find(family, style) is not { } file) return null;
        var built = EmbeddedFontBuilder.Build(file.Data, all, out _, file.CollectionIndex);
        if (built is null || TrueTypeFont.TryParse(file.Data, file.CollectionIndex) is not { } measure) return null;
        return new PdfDrawFont(AddType0(built), built, measure);
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

        var map = font.ToUnicode().Select(p => new KeyValuePair<int, string>(p.Key, char.ConvertFromUtf32(p.Value)));
        var toUnicode = document.Add(Flate(new PdfDictionary(), ToUnicodeCMap.Write(map)));

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

    internal PdfDrawFont(PdfReference reference, Standard14 standard)
    {
        Reference = reference;
        _standard = standard;
        Ascent = standard.Ascent / 1000.0;
        Descent = standard.Descent / 1000.0;
    }

    internal PdfDrawFont(PdfReference reference, EmbeddedFont embedded, TrueTypeFont measure)
    {
        Reference = reference;
        _embedded = embedded;
        _measure = measure;
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

    /// <summary>The string as the bytes a <c>Tj</c> shows: one byte a character, or two for an embedded font.</summary>
    public byte[] Encode(string text)
    {
        if (_embedded is not null) return _embedded.Encode(text);
        return [.. text.EnumerateRunes().Where(r => r.Value >= 0x20).Select(r => (byte)PdfFontEmbedder.WinAnsiCode(r.Value))];
    }

    /// <summary>The width of the text set in <paramref name="size"/> points, kerning not applied.</summary>
    public double Width(string text, double size)
    {
        double units = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value >= 0x20) units += Advance(rune.Value);
        }
        return units * size / 1000;
    }

    private double Advance(int codePoint)
    {
        if (_measure is not null) return _measure.GetAdvance(_measure.GlyphForCodePoint(codePoint)) * 1000.0 / _measure.UnitsPerEm;
        int code = PdfFontEmbedder.WinAnsiCode(codePoint);
        return PdfEncodings.WinAnsi[code] is { } name ? _standard!.WidthOf(name) ?? 0 : 0;
    }

    /// <summary>
    /// Breaks the text into lines no wider than <paramref name="maxWidth"/>: at spaces, a word wider
    /// than the box at the character, and at every newline. A line keeps no trailing space.
    /// </summary>
    public IReadOnlyList<string> Wrap(string text, double size, double maxWidth)
    {
        var lines = new List<string>();
        foreach (string paragraph in text.ReplaceLineEndings("\n").Split('\n'))
        {
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
        }
        return lines;
    }
}
