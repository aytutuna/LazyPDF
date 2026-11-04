using static LazyPDF.Core.FontBytes;

namespace LazyPDF.Core;

public sealed partial class TrueTypeFont
{
    private readonly record struct CmapSubtable(int Platform, int Encoding, int Offset);

    private CmapSubtable[] _cmaps = [];
    private int _unicode = -1;
    private int _symbol = -1;

    private void ReadCmapDirectory()
    {
        var cmap = Table("cmap");
        var count = Math.Min(U16(cmap, 2), (cmap.Length - 4) / 8);
        var list = new List<CmapSubtable>(count);
        for (var i = 0; i < count; i++)
        {
            var offset = Offset32(cmap, 4 + 8 * i + 4);
            if (offset > 0 && offset < cmap.Length - 4)
                list.Add(new CmapSubtable(U16(cmap, 4 + 8 * i), U16(cmap, 4 + 8 * i + 2), offset));
        }
        _cmaps = list.ToArray();

        // Wide subtables first so code points above the BMP resolve.
        (int, int)[] unicodeOrder = [(3, 10), (0, 6), (0, 4), (3, 1), (0, 3), (0, 2), (0, 1), (0, 0)];
        foreach (var (p, e) in unicodeOrder)
        {
            for (var i = 0; i < _cmaps.Length && _unicode < 0; i++)
                if (_cmaps[i].Platform == p && _cmaps[i].Encoding == e && IsLookupFormat(U16(cmap, _cmaps[i].Offset))) _unicode = i;
            if (_unicode >= 0) break;
        }
        _symbol = Array.FindIndex(_cmaps, c => c.Platform == 3 && c.Encoding == 0);
    }

    private static bool IsLookupFormat(int format) => format is 0 or 4 or 6 or 12 or 13;

    /// <summary>True when the font has a cmap subtable for the platform and encoding IDs.</summary>
    public bool HasCmap(int platformId, int encodingId) =>
        Array.Exists(_cmaps, c => c.Platform == platformId && c.Encoding == encodingId);

    /// <summary>
    /// Glyph for a Unicode code point, 0 (.notdef) when the font has none. A font with only a (3,0) symbol
    /// subtable is asked for the code itself and for 0xF000 plus it, the way viewers do.
    /// </summary>
    public int GlyphForCodePoint(int codePoint)
    {
        var cmap = Table("cmap");
        if (_unicode >= 0)
        {
            var g = Lookup(cmap, _cmaps[_unicode].Offset, codePoint);
            if (g != 0) return g;
        }
        if (_unicode < 0 && _symbol >= 0 && codePoint is >= 0 and < 256)
        {
            var offset = _cmaps[_symbol].Offset;
            var g = Lookup(cmap, offset, codePoint);
            return g != 0 ? g : Lookup(cmap, offset, 0xF000 + codePoint);
        }
        return 0;
    }

    /// <summary>Glyph for a code in one named cmap subtable, 0 when the subtable or the code is absent.</summary>
    public int GlyphForCmap(int platformId, int encodingId, int code)
    {
        var i = Array.FindIndex(_cmaps, c => c.Platform == platformId && c.Encoding == encodingId);
        return i < 0 ? 0 : Lookup(Table("cmap"), _cmaps[i].Offset, code);
    }

    /// <summary>
    /// Glyph for a base character followed by a variation selector, from the format 14 subtable (0,5).
    /// Returns 0 when the font lists no such sequence; a default sequence gives the base character's glyph.
    /// </summary>
    public int GlyphForVariation(int codePoint, int variationSelector)
    {
        var i = Array.FindIndex(_cmaps, c => c.Platform == 0 && c.Encoding == 5);
        if (i < 0) return 0;
        var cmap = Table("cmap");
        var sub = cmap[_cmaps[i].Offset..];
        if (U16(sub, 0) != 14) return 0;

        var count = Math.Min(Offset32(sub, 6), (sub.Length - 10) / 11);
        var lo = 0;
        var hi = count - 1;
        while (lo <= hi)
        {
            var mid = (lo + hi) / 2;
            var rec = 10 + 11 * mid;
            var vs = U24(sub, rec);
            if (vs < variationSelector) lo = mid + 1;
            else if (vs > variationSelector) hi = mid - 1;
            else
            {
                var nonDefault = Offset32(sub, rec + 7);
                if (nonDefault > 0)
                {
                    var n = Math.Min(Offset32(sub, nonDefault), (sub.Length - nonDefault - 4) / 5);
                    int a = 0, b = n - 1;
                    while (a <= b)
                    {
                        var m = (a + b) / 2;
                        var at = nonDefault + 4 + 5 * m;
                        var u = U24(sub, at);
                        if (u < codePoint) a = m + 1;
                        else if (u > codePoint) b = m - 1;
                        else return U16(sub, at + 3);
                    }
                }
                var def = Offset32(sub, rec + 3);
                if (def > 0)
                {
                    var n = Math.Min(Offset32(sub, def), (sub.Length - def - 4) / 4);
                    int a = 0, b = n - 1;
                    while (a <= b)
                    {
                        var m = (a + b) / 2;
                        var at = def + 4 + 4 * m;
                        var start = U24(sub, at);
                        if (codePoint < start) b = m - 1;
                        else if (codePoint > start + U8(sub, at + 3)) a = m + 1;
                        else return GlyphForCodePoint(codePoint);
                    }
                }
                return 0;
            }
        }
        return 0;
    }

    private static int Lookup(ReadOnlySpan<byte> cmap, int offset, int code)
    {
        if (code < 0) return 0;
        var t = cmap[offset..];
        switch (U16(t, 0))
        {
            case 0:
                return code < 256 ? U8(t, 6 + code) : 0;
            case 4:
                return LookupFormat4(t, code);
            case 6:
            {
                var first = U16(t, 6);
                var n = U16(t, 8);
                return code >= first && code - first < n ? U16(t, 10 + 2 * (code - first)) : 0;
            }
            case 12 or 13:
            {
                var n = Math.Min(Offset32(t, 12), (t.Length - 16) / 12);
                var lo = 0;
                var hi = n - 1;
                while (lo <= hi)
                {
                    var mid = (lo + hi) / 2;
                    var g = 16 + 12 * mid;
                    var start = U32(t, g);
                    if (code < start) hi = mid - 1;
                    else if (code > U32(t, g + 4)) lo = mid + 1;
                    else
                    {
                        var gid = U32(t, g + 8);
                        gid = U16(t, 0) == 13 ? gid : gid + (uint)code - start;
                        return gid > 0xFFFF ? 0 : (int)gid;
                    }
                }
                return 0;
            }
            default:
                return 0;
        }
    }

    private static int LookupFormat4(ReadOnlySpan<byte> t, int code)
    {
        if (code > 0xFFFF) return 0;
        var segCount = Math.Min(U16(t, 6) / 2, (t.Length - 16) / 8);
        var ends = 14;
        var starts = 16 + 2 * segCount;
        var deltas = starts + 2 * segCount;
        var ranges = deltas + 2 * segCount;

        int lo = 0, hi = segCount - 1;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (U16(t, ends + 2 * mid) < code) lo = mid + 1;
            else hi = mid;
        }
        if (lo >= segCount || U16(t, ends + 2 * lo) < code || U16(t, starts + 2 * lo) > code) return 0;

        var delta = U16(t, deltas + 2 * lo);
        var range = U16(t, ranges + 2 * lo);
        if (range == 0) return (code + delta) & 0xFFFF;
        var g = U16(t, ranges + 2 * lo + range + 2 * (code - U16(t, starts + 2 * lo)));
        return g == 0 ? 0 : (g + delta) & 0xFFFF;
    }
}
