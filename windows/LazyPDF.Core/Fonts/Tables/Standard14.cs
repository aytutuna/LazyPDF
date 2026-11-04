using System.Globalization;

namespace LazyPDF.Core;

/// <summary>A font's bounding box in glyph space (1000 units to the em).</summary>
public readonly record struct FontBox(int Left, int Bottom, int Right, int Top);

/// <summary>
/// One of the 14 standard fonts (ISO 32000-1 9.6.2.2) with the metrics of its Adobe AFM file.
/// <see cref="Find"/> also answers to the names other programs give them: Arial, TimesNewRomanPS-BoldMT.
/// </summary>
public sealed class Standard14
{
    readonly Dictionary<string, int> _widths;

    Standard14(string[] f, Dictionary<string, int> widths)
    {
        Name = f[1];
        Ascent = int.Parse(f[2], CultureInfo.InvariantCulture);
        Descent = int.Parse(f[3], CultureInfo.InvariantCulture);
        BBox = new FontBox(int.Parse(f[4], CultureInfo.InvariantCulture), int.Parse(f[5], CultureInfo.InvariantCulture),
            int.Parse(f[6], CultureInfo.InvariantCulture), int.Parse(f[7], CultureInfo.InvariantCulture));
        CapHeight = int.Parse(f[8], CultureInfo.InvariantCulture);
        XHeight = int.Parse(f[9], CultureInfo.InvariantCulture);
        ItalicAngle = double.Parse(f[10], CultureInfo.InvariantCulture);
        StemV = int.Parse(f[11], CultureInfo.InvariantCulture);
        IsFixedPitch = f[12] == "1";
        IsBold = f[13] == "1";
        _widths = widths;
    }

    /// <summary>The BaseFont name: "Helvetica-Bold", "Times-Roman", "Symbol".</summary>
    public string Name { get; }

    /// <summary>The AFM's Ascender and Descender (negative); the bounding box's top and bottom for Symbol and ZapfDingbats, which have none.</summary>
    public int Ascent { get; }

    public int Descent { get; }

    public FontBox BBox { get; }

    /// <summary>Zero where the AFM gives none (Symbol, ZapfDingbats).</summary>
    public int CapHeight { get; }

    public int XHeight { get; }

    public double ItalicAngle { get; }

    public int StemV { get; }

    public bool IsFixedPitch { get; }

    public bool IsBold { get; }

    public bool IsItalic => ItalicAngle != 0;

    public bool IsSerif => Name.StartsWith("Times", StringComparison.Ordinal);

    /// <summary>Symbol and ZapfDingbats, whose encoding is built in and not a Latin one.</summary>
    public bool IsSymbolic => Name is "Symbol" or "ZapfDingbats";

    /// <summary>The /Flags of a FontDescriptor for the font (ISO 32000-1 9.8.2).</summary>
    public int Flags => (IsFixedPitch ? 1 : 0) | (IsSerif ? 2 : 0) | (IsSymbolic ? 4 : 32) | (IsItalic ? 64 : 0) | (IsBold ? 1 << 18 : 0);

    /// <summary>What a code shows when the font has no /Encoding: Symbol's and ZapfDingbats' own, else StandardEncoding.</summary>
    public IReadOnlyList<string?> BuiltInEncoding => Name switch
    {
        "Symbol" => PdfEncodings.Symbol,
        "ZapfDingbats" => PdfEncodings.ZapfDingbats,
        _ => PdfEncodings.Standard,
    };

    /// <summary>The advance of a glyph in 1/1000 em, or null when the font has no glyph of that name.</summary>
    public int? WidthOf(string glyphName) => _widths.TryGetValue(glyphName, out int w) ? w : null;

    static readonly Lazy<Standard14[]> Fonts = new(Load);

    // Longest first: "TimesNewRoman" before "Times".
    static readonly (string Prefix, string Family)[] Families =
    [
        ("TimesNewRoman", "Times"), ("Times", "Times"), ("Arial", "Helvetica"), ("Helvetica", "Helvetica"),
        ("CourierNew", "Courier"), ("Courier", "Courier"), ("Symbol", "Symbol"), ("ZapfDingbats", "ZapfDingbats"),
    ];

    public static IReadOnlyList<Standard14> All => Fonts.Value;

    /// <summary>
    /// The standard font a BaseFont name stands for, or null. A subset tag (ABCDEF+) is ignored, so are
    /// case, spaces, and the "PS" and "MT" of the Windows names; "Arial Narrow" and "Arial Black" are other fonts and give null.
    /// </summary>
    public static Standard14? Find(string baseFont)
    {
        string name = baseFont.Length > 7 && baseFont[6] == '+' ? baseFont[7..] : baseFont;
        name = name.Replace(" ", "");
        foreach (var (prefix, family) in Families)
        {
            if (!name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                continue;
            string rest = name[prefix.Length..].Replace("-", "").Replace(",", "");
            rest = Strip(Strip(rest, "PS"), "MT");
            if (family is "Symbol" or "ZapfDingbats")
                return rest.Length == 0 ? ByName(family) : null;

            bool bold = rest.Contains("Bold", StringComparison.OrdinalIgnoreCase);
            bool italic = rest.Contains("Italic", StringComparison.OrdinalIgnoreCase) || rest.Contains("Oblique", StringComparison.OrdinalIgnoreCase);
            foreach (var word in new[] { "Bold", "Italic", "Oblique", "Roman", "Regular", "Normal" })
                rest = Strip(rest, word);
            if (rest.Length != 0)
                return null;

            string style = (bold, italic) switch
            {
                (false, false) => family == "Times" ? "-Roman" : "",
                (true, false) => "-Bold",
                (false, true) => family == "Times" ? "-Italic" : "-Oblique",
                _ => family == "Times" ? "-BoldItalic" : "-BoldOblique",
            };
            return ByName(family + style);
        }
        return null;
    }

    static Standard14? ByName(string name) => Fonts.Value.FirstOrDefault(f => f.Name == name);

    static string Strip(string s, string word) => s.Replace(word, "", StringComparison.OrdinalIgnoreCase);

    static Standard14[] Load()
    {
        var fonts = new List<Standard14>(14);
        string[]? header = null;
        foreach (var line in TableBlob.InflateText(Standard14Data.Fonts).Split('\n'))
        {
            if (line.StartsWith("F ", StringComparison.Ordinal))
            {
                header = line.Split(' ');
                continue;
            }
            var parts = line.Split(' ');
            var widths = new Dictionary<string, int>((parts.Length - 1) / 2, StringComparer.Ordinal);
            for (int i = 1; i + 1 < parts.Length; i += 2)
                widths[parts[i]] = int.Parse(parts[i + 1], CultureInfo.InvariantCulture);
            fonts.Add(new Standard14(header!, widths));
        }
        return [.. fonts];
    }
}
