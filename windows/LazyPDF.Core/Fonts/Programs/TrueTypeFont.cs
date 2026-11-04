using System.Text;
using static LazyPDF.Core.FontBytes;

namespace LazyPDF.Core;

/// <summary>
/// An sfnt font: TrueType outlines (glyf) or OpenType with CFF outlines. Parses over the caller's array
/// and tolerates broken tables: a missing or truncated table gives zeros and empty outlines, never an exception.
/// </summary>
public sealed partial class TrueTypeFont
{
    private readonly byte[] _data;
    private readonly Dictionary<string, (int Offset, int Length)> _tables;
    private readonly int _locaFormat;
    private readonly int _hMetricCount;

    private TrueTypeFont(byte[] data, Dictionary<string, (int Offset, int Length)> tables)
    {
        _data = data;
        _tables = tables;

        var head = Table("head");
        UnitsPerEm = U16(head, 18);
        if (UnitsPerEm is < 16 or > 16384) UnitsPerEm = 1000;
        FontBounds = new GlyphBounds(I16(head, 36), I16(head, 38), I16(head, 40), I16(head, 42));
        IsBoldStyle = (U16(head, 44) & 1) != 0;
        _locaFormat = I16(head, 50);

        var maxp = Table("maxp");
        GlyphCount = U16(maxp, 4);

        var hhea = Table("hhea");
        Ascent = I16(hhea, 4);
        Descent = I16(hhea, 6);
        LineGap = I16(hhea, 8);
        _hMetricCount = U16(hhea, 34);

        var os2 = Table("OS/2");
        if (os2.Length >= 10)
        {
            WeightClass = U16(os2, 4);
            FsType = U16(os2, 8);
            if (Ascent == 0 && Descent == 0)
            {
                Ascent = I16(os2, 68);
                Descent = I16(os2, 70);
                if (Ascent == 0 && Descent == 0)
                {
                    Ascent = U16(os2, 74);
                    Descent = -U16(os2, 76);
                }
            }
            if (U16(os2, 0) >= 2 && os2.Length >= 90)
            {
                XHeight = I16(os2, 86);
                CapHeight = I16(os2, 88);
            }
        }

        var post = Table("post");
        ItalicAngle = I16(post, 4) + U16(post, 6) / 65536.0;
        IsFixedPitch = U32(post, 12) != 0;

        if (_tables.TryGetValue("CFF ", out var cff))
            Cff = CffFont.TryParse(data, cff.Offset, cff.Length);
        ReadCmapDirectory();
        if (CapHeight == 0) CapHeight = GuessCapHeight();
    }

    /// <summary>1 for a plain font file, the number of fonts in a collection (.ttc), 0 when the bytes are no sfnt.</summary>
    public static int CollectionCount(byte[] data)
    {
        if (data.Length < 12) return 0;
        var tag = Tag(data, 0);
        if (tag == "ttcf") return (int)Math.Min(U32(data, 8), 4096);
        return IsSfntTag(data) ? 1 : 0;
    }

    /// <summary>Opens the font at <paramref name="collectionIndex"/> (0 for a plain file), or null when it has no usable head and maxp.</summary>
    public static TrueTypeFont? TryParse(byte[] data, int collectionIndex = 0)
    {
        var count = CollectionCount(data);
        if (count == 0 || collectionIndex < 0 || collectionIndex >= count) return null;

        var dir = 0;
        if (Tag(data, 0) == "ttcf")
        {
            dir = Offset32(data, 12 + 4 * collectionIndex);
            if (dir <= 0 || dir > data.Length - 12 || !IsSfntTag(data.AsSpan(dir))) return null;
        }

        var numTables = Math.Min(U16(data, dir + 4), (data.Length - dir - 12) / 16);
        var tables = new Dictionary<string, (int Offset, int Length)>(numTables);
        for (var i = 0; i < numTables; i++)
        {
            var e = dir + 12 + 16 * i;
            var offset = Offset32(data, e + 8);
            var length = Offset32(data, e + 12);
            if (offset <= 0 || offset >= data.Length) continue;
            length = Math.Min(length, data.Length - offset);
            tables.TryAdd(Tag(data, e), (offset, length));
        }
        if (!tables.TryGetValue("head", out var head) || head.Length < 54) return null;
        if (!tables.TryGetValue("maxp", out var maxp) || maxp.Length < 6) return null;
        return new TrueTypeFont(data, tables);
    }

    private static bool IsSfntTag(ReadOnlySpan<byte> d)
    {
        var v = U32(d, 0);
        return v == 0x00010000 || v == 0x4F54544F || v == 0x74727565;
    }

    public int UnitsPerEm { get; }

    public int GlyphCount { get; }

    /// <summary>Typographic ascent in font units (hhea, else OS/2), positive.</summary>
    public int Ascent { get; }

    /// <summary>Descent in font units, negative below the baseline.</summary>
    public int Descent { get; }

    public int LineGap { get; }

    public int CapHeight { get; private set; }

    public int XHeight { get; }

    /// <summary>Box around all glyphs, from head.</summary>
    public GlyphBounds FontBounds { get; }

    public double ItalicAngle { get; }

    public bool IsFixedPitch { get; }

    public bool IsBoldStyle { get; }

    /// <summary>usWeightClass of OS/2, 400 when the table is absent.</summary>
    public int WeightClass { get; } = 400;

    /// <summary>The OS/2 licensing bits, 0 (installable) when the font has no OS/2 table.</summary>
    public int FsType { get; }

    /// <summary>
    /// False for fonts whose license restricts embedding (fsType 0x0002) or that allow only bitmaps (0x0200)
    /// (OpenType spec, OS/2 fsType). Preview and print, and editable embedding, are allowed.
    /// </summary>
    public bool EmbeddingAllowed => (FsType & 0x000E) != 0x0002 && (FsType & 0x0200) == 0;

    /// <summary>False when fsType 0x0100 says the whole font must be embedded.</summary>
    public bool SubsettingAllowed => (FsType & 0x0100) == 0;

    /// <summary>The CFF outlines of an OpenType/CFF font, null for TrueType outlines.</summary>
    public CffFont? Cff { get; }

    public bool IsCff => Cff != null;

    /// <summary>True when the font has outlines this class can read.</summary>
    public bool HasOutlines => Cff != null || (HasTable("glyf") && HasTable("loca"));

    public bool HasTable(string tag) => _tables.ContainsKey(tag);

    internal ReadOnlySpan<byte> Table(string tag) =>
        _tables.TryGetValue(tag, out var t) ? _data.AsSpan(t.Offset, t.Length) : default;

    /// <summary>Advance width of the glyph in font units, 0 for a glyph the font does not have.</summary>
    public int GetAdvance(int glyphId)
    {
        if (glyphId < 0 || glyphId >= GlyphCount || _hMetricCount == 0) return 0;
        var hmtx = Table("hmtx");
        return U16(hmtx, 4 * Math.Min(glyphId, _hMetricCount - 1));
    }

    /// <summary>Left side bearing of the glyph from hmtx.</summary>
    internal int GetLeftSideBearing(int glyphId)
    {
        if (glyphId < 0 || glyphId >= GlyphCount) return 0;
        var hmtx = Table("hmtx");
        return glyphId < _hMetricCount
            ? I16(hmtx, 4 * glyphId + 2)
            : I16(hmtx, 4 * _hMetricCount + 2 * (glyphId - _hMetricCount));
    }

    private int GuessCapHeight()
    {
        var h = GlyphForCodePoint('H');
        if (h != 0 && GetBounds(h) is { } b && b.YMax > 0) return (int)b.YMax;
        return UnitsPerEm * 7 / 10;
    }

    /// <summary>Family name (name ID 1), null when the table has none.</summary>
    public string? FamilyName => ReadName(1);

    /// <summary>PostScript name (name ID 6), null when the table has none.</summary>
    public string? PostScriptName => ReadName(6);

    private string? ReadName(int id)
    {
        var name = Table("name");
        var count = Math.Min(U16(name, 2), (name.Length - 6) / 12);
        var storage = U16(name, 4);
        string? best = null;
        var bestRank = 0;
        for (var i = 0; i < count; i++)
        {
            var r = 6 + 12 * i;
            if (U16(name, r + 6) != id) continue;
            var platform = U16(name, r);
            var rank = platform switch
            {
                3 when U16(name, r + 4) == 0x409 => 4,
                3 => 3,
                0 => 2,
                1 when U16(name, r + 4) == 0 => 1,
                _ => 0,
            };
            if (rank <= bestRank) continue;
            var length = U16(name, r + 8);
            var start = storage + U16(name, r + 10);
            if (start > name.Length || length > name.Length - start) continue;
            var raw = name.Slice(start, length);
            best = platform == 1 ? Encoding.Latin1.GetString(raw) : Encoding.BigEndianUnicode.GetString(raw);
            bestRank = rank;
        }
        return best;
    }
}
