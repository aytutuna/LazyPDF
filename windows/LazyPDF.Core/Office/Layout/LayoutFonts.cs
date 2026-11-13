namespace LazyPDF.Core.Office;

/// <summary>One font file at one style, parsed for measuring.</summary>
internal sealed class FontFace
{
    private readonly Dictionary<int, double> _advances = [];

    public FontFace(string family, FontStyles style, TrueTypeFont font, FontFile file)
    {
        Family = family;
        File = file;
        Style = style;
        Font = font;
        Ascent = (font.Ascent + font.LineGap) / (double)font.UnitsPerEm;
        Descent = -font.Descent / (double)font.UnitsPerEm;
    }

    public string Family { get; }
    public FontStyles Style { get; }
    public TrueTypeFont Font { get; }
    public FontFile File { get; }

    /// <summary>In em, the line gap included so that a single-spaced line is ascent plus descent.</summary>
    public double Ascent { get; }
    public double Descent { get; }

    public bool Covers(int codePoint) => Font.GlyphForCodePoint(codePoint) != 0;

    /// <summary>In em; no kerning.</summary>
    public double Advance(int codePoint)
    {
        if (_advances.TryGetValue(codePoint, out double known)) return known;
        double advance = Font.GetAdvance(Font.GlyphForCodePoint(codePoint)) / (double)Font.UnitsPerEm;
        _advances[codePoint] = advance;
        return advance;
    }
}

/// <summary>The faces a document asks for, and per character the face that has a glyph.</summary>
internal sealed class LayoutFonts(IFontSource? source)
{
    // Tried in this order when the family of a run has no glyph for a character.
    private static readonly string[] Fallbacks =
        ["Segoe UI", "Segoe UI Symbol", "Microsoft YaHei", "Yu Gothic", "Malgun Gothic", "Arial Unicode MS", "PingFang SC", "Hiragino Sans", "Apple SD Gothic Neo", "Liberation Sans"];

    private readonly Dictionary<(string, FontStyles), FontFace?> _faces = [];
    private readonly Dictionary<(byte[], int, FontStyles), FontFace?> _byFile = new(FileKeyComparer.Instance);
    private readonly Dictionary<(FontFace, int), FontFace?> _chosen = [];

    // The data array by reference: a source that hands the same bytes back is the same file.
    private sealed class FileKeyComparer : IEqualityComparer<(byte[], int, FontStyles)>
    {
        public static readonly FileKeyComparer Instance = new();

        public bool Equals((byte[], int, FontStyles) a, (byte[], int, FontStyles) b) =>
            ReferenceEquals(a.Item1, b.Item1) && a.Item2 == b.Item2 && a.Item3 == b.Item3;

        public int GetHashCode((byte[], int, FontStyles) k) =>
            HashCode.Combine(System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(k.Item1), k.Item2, k.Item3);
    }

    /// <summary>The shaper the writer will draw with; text it joins is measured through it too.</summary>
    public IShaper? Shaper { get; } = (source as OfficeFontSource)?.Shaper;

    /// <summary>Code points no face could draw.</summary>
    public SortedSet<int> Missing { get; } = [];

    public FontFace? Find(string family, FontStyles style)
    {
        if (_faces.TryGetValue((family, style), out var known)) return known;
        FontFace? face = null;
        if (source?.Find(family, style) is { } file)
        {
            // Names that resolve to the same file share one face (and one embedded subset); the first name stays on it.
            if (!_byFile.TryGetValue((file.Data, file.CollectionIndex, style), out face))
            {
                if (TrueTypeFont.TryParse(file.Data, file.CollectionIndex) is { } font && font.UnitsPerEm > 0)
                {
                    face = new FontFace(family, style, font, file);
                }
                _byFile[(file.Data, file.CollectionIndex, style)] = face;
            }
        }
        _faces[(family, style)] = face;
        return face;
    }

    /// <summary>The face to draw <paramref name="codePoint"/> with: <paramref name="primary"/> if it has the glyph, else the first fallback that has.</summary>
    public FontFace Choose(FontFace primary, int codePoint)
    {
        if (_chosen.TryGetValue((primary, codePoint), out var known)) return known ?? primary;
        FontFace? chosen = primary.Covers(codePoint) ? primary : null;
        if (chosen is null)
        {
            foreach (string family in Fallbacks)
            {
                if (Find(family, primary.Style) is { } face && face.Covers(codePoint))
                {
                    chosen = face;
                    break;
                }
            }
        }
        if (chosen is null) Missing.Add(codePoint);
        _chosen[(primary, codePoint)] = chosen;
        return chosen ?? primary;
    }
}
