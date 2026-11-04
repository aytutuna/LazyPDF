using System.Globalization;
using System.Text;
using static LazyPDF.Core.FontBytes;

namespace LazyPDF.Core;

/// <summary>
/// A Compact Font Format program (Adobe TN 5176), bare as in a PDF's FontFile3 /Type1C and /CIDFontType0C
/// or taken from the 'CFF ' table of an OpenType font. Name-keyed and CID-keyed fonts are both read.
/// Charstring type 2 only; a font that breaks the format makes <see cref="TryParse"/> return null.
/// </summary>
public sealed class CffFont
{
    private const int MaxGlyphs = 65535;
    private const int MaxFontDicts = 256;
    internal const int MaxDictSize = 1 << 16;

    private readonly byte[] _d;
    private readonly CffIndex _strings;
    private readonly CffIndex _charStrings;
    private readonly int[] _charset;
    private readonly int[] _encoding = new int[256];
    private Dictionary<string, int>? _nameToGlyph;
    private Dictionary<int, int>? _idToGlyph;

    internal CffIndex GlobalSubrs { get; }

    internal CffPrivate[] Privates { get; }

    internal byte[]? FdSelect { get; }

    private CffFont(byte[] d, string name, CffIndex strings, CffIndex gsubrs, CffIndex charStrings, int[] charset,
        CffPrivate[] privates, byte[]? fdSelect, bool isCid, double[] matrix, GlyphBounds? bbox)
    {
        _d = d;
        Name = name;
        _strings = strings;
        GlobalSubrs = gsubrs;
        _charStrings = charStrings;
        _charset = charset;
        Privates = privates;
        FdSelect = fdSelect;
        IsCid = isCid;
        FontMatrix = matrix;
        FontBounds = bbox;
    }

    /// <summary>The font name from the Name INDEX.</summary>
    public string Name { get; }

    public bool IsCid { get; }

    public int GlyphCount => _charStrings.Count;

    /// <summary>The top dictionary's FontMatrix, 0.001 0 0 0.001 0 0 by default; a CID font's first font DICT adds its own, multiplied in.</summary>
    public double[] FontMatrix { get; }

    public GlyphBounds? FontBounds { get; }

    internal byte[] Bytes => _d;

    internal ReadOnlySpan<byte> CharString(int gid) => _charStrings.Item(_d, gid);

    public static CffFont? TryParse(byte[] data) => TryParse(data, 0, data.Length);

    /// <summary>Parses the CFF data at <paramref name="offset"/>, <paramref name="length"/> bytes long. The bytes are copied.</summary>
    public static CffFont? TryParse(byte[] data, int offset, int length)
    {
        if (offset < 0 || length < 4 || length > data.Length - offset) return null;
        var d = data.AsSpan(offset, length).ToArray();
        try
        {
            return Read(d);
        }
        catch (Exception e) when (e is FormatException or IndexOutOfRangeException or ArgumentException or OverflowException)
        {
            return null;
        }
    }

    private static CffFont? Read(byte[] d)
    {
        if (d[0] != 1) return null;
        var pos = U8(d, 2);
        if (!CffIndex.TryRead(d, pos, out var names)) return null;
        if (!CffIndex.TryRead(d, names.End, out var tops)) return null;
        if (!CffIndex.TryRead(d, tops.End, out var strings)) return null;
        if (!CffIndex.TryRead(d, strings.End, out var gsubrs)) return null;
        if (tops.Count < 1) return null;

        var top = CffDict.Parse(tops.Item(d, 0));
        var charStringsAt = (int)top.Number(17, 0);
        if (charStringsAt <= 0 || !CffIndex.TryRead(d, charStringsAt, out var charStrings)) return null;
        var glyphCount = Math.Min(charStrings.Count, MaxGlyphs);

        var isCid = top.Has(1230);
        var privates = new List<CffPrivate>();
        byte[]? fdSelect = null;
        double[]? cidMatrix = null;
        if (isCid)
        {
            var fdArrayAt = (int)top.Number(1236, 0);
            if (fdArrayAt <= 0 || !CffIndex.TryRead(d, fdArrayAt, out var fdArray)) return null;
            // Font DICTs may overlap, so each one is cut to a size no real one reaches.
            for (var i = 0; i < Math.Min(fdArray.Count, MaxFontDicts); i++)
            {
                var fontDict = CffDict.Parse(Head(fdArray.Item(d, i)));
                if (i == 0 && fontDict.Numbers(1207) is { Length: 6 } fdMatrix) cidMatrix = fdMatrix;
                privates.Add(CffPrivate.Read(d, fontDict));
            }
            fdSelect = ReadFdSelect(d, (int)top.Number(1237, 0), glyphCount);
            if (privates.Count == 0) return null;
        }
        else privates.Add(CffPrivate.Read(d, top));

        var charset = ReadCharset(d, (int)top.Number(15, 0), glyphCount, isCid);
        var matrix = CombinedMatrix(top.Numbers(1207) is { Length: 6 } m ? m : null, cidMatrix);
        GlyphBounds? bbox = top.Numbers(5) is { Length: 4 } b ? new GlyphBounds(b[0], b[1], b[2], b[3]) : null;
        var name = names.Count > 0 ? Encoding.Latin1.GetString(names.Item(d, 0)) : "";

        var font = new CffFont(d, name, strings, gsubrs, charStrings, charset, privates.ToArray(), fdSelect, isCid, matrix, bbox);
        if (!isCid) font.ReadEncoding((int)top.Number(16, 0));
        return font;
    }

    // The top DICT's matrix and a font DICT's multiply; with only one of them that one stands alone (the top one
    // defaults to 0.001, which a font DICT's matrix would otherwise scale twice).
    private static double[] CombinedMatrix(double[]? top, double[]? fd)
    {
        if (fd is null) return top ?? [0.001, 0, 0, 0.001, 0, 0];
        if (top is null) return fd;
        return
        [
            fd[0] * top[0] + fd[1] * top[2], fd[0] * top[1] + fd[1] * top[3],
            fd[2] * top[0] + fd[3] * top[2], fd[2] * top[1] + fd[3] * top[3],
            fd[4] * top[0] + fd[5] * top[2] + top[4], fd[4] * top[1] + fd[5] * top[3] + top[5],
        ];
    }

    private static ReadOnlySpan<byte> Head(ReadOnlySpan<byte> dict) => dict[..Math.Min(dict.Length, MaxDictSize)];

    private static int[] ReadCharset(byte[] d, int at, int glyphCount, bool isCid)
    {
        var sids = new int[glyphCount];
        if (at <= 2)
        {
            // The predefined charsets are only exact for ISOAdobe; Expert ones fall back to identity.
            for (var g = 1; g < glyphCount; g++) sids[g] = at == 0 && !isCid ? Math.Min(g, 228) : g;
            return sids;
        }

        var format = U8(d, at);
        var p = at + 1;
        var gid = 1;
        if (format == 0)
        {
            for (; gid < glyphCount && p <= d.Length - 2; gid++, p += 2) sids[gid] = U16(d, p);
        }
        else if (format is 1 or 2)
        {
            var width = format == 1 ? 3 : 4;
            while (gid < glyphCount && p <= d.Length - width)
            {
                var first = U16(d, p);
                var left = format == 1 ? U8(d, p + 2) : U16(d, p + 2);
                p += width;
                for (var i = 0; i <= left && gid < glyphCount; i++) sids[gid++] = first + i;
            }
        }
        return sids;
    }

    private static byte[]? ReadFdSelect(byte[] d, int at, int glyphCount)
    {
        if (at <= 0) return null;
        var map = new byte[glyphCount];
        var format = U8(d, at);
        if (format == 0)
        {
            for (var g = 0; g < glyphCount; g++) map[g] = (byte)U8(d, at + 1 + g);
        }
        else if (format == 3)
        {
            var ranges = U16(d, at + 1);
            var p = at + 3;
            var filled = 0;
            for (var r = 0; r < ranges && p <= d.Length - 5; r++, p += 3)
            {
                var first = U16(d, p);
                var fd = (byte)U8(d, p + 2);
                var next = Math.Min(U16(d, p + 3), glyphCount);
                // Ranges ascend; one that starts inside the last is cut so that no glyph is written twice.
                for (var g = Math.Max(first, filled); g < next; g++) map[g] = fd;
                filled = Math.Max(filled, next);
            }
        }
        else return null;
        return map;
    }

    private void ReadEncoding(int at)
    {
        if (at == 0)
        {
            var bySid = SidToGlyph();
            for (var c = 0; c < 256; c++)
            {
                var sid = StandardNames.StandardEncodingSids[c];
                if (sid != 0 && bySid.TryGetValue(sid, out var g)) _encoding[c] = g;
            }
            return;
        }
        if (at == 1) return;

        var format = U8(_d, at);
        var p = at + 1;
        if ((format & 0x7F) == 0)
        {
            var n = U8(_d, p++);
            for (var i = 0; i < n && p < _d.Length; i++) _encoding[U8(_d, p++)] = i + 1;
        }
        else if ((format & 0x7F) == 1)
        {
            var ranges = U8(_d, p++);
            var gid = 1;
            for (var r = 0; r < ranges && p <= _d.Length - 2; r++, p += 2)
            {
                var first = U8(_d, p);
                for (var i = 0; i <= U8(_d, p + 1); i++)
                    if (first + i < 256) _encoding[first + i] = gid++;
            }
        }
        if ((format & 0x80) != 0)
        {
            var n = U8(_d, p++);
            var bySid = SidToGlyph();
            for (var i = 0; i < n && p <= _d.Length - 3; i++, p += 3)
                if (bySid.TryGetValue(U16(_d, p + 1), out var g)) _encoding[U8(_d, p)] = g;
        }
    }

    private Dictionary<int, int> SidToGlyph()
    {
        if (_idToGlyph != null) return _idToGlyph;
        var map = new Dictionary<int, int>(_charset.Length);
        for (var g = _charset.Length - 1; g >= 0; g--) map[_charset[g]] = g;
        return _idToGlyph = map;
    }

    /// <summary>Glyph for a code of the font's built-in encoding (name-keyed fonts), 0 when unassigned.</summary>
    public int GlyphForCode(int code) => code is >= 0 and < 256 ? _encoding[code] : 0;

    /// <summary>The glyph name, null for a CID-keyed font or a glyph out of range.</summary>
    public string? GlyphName(int glyphId)
    {
        if (IsCid || glyphId < 0 || glyphId >= _charset.Length) return null;
        var sid = _charset[glyphId];
        if (sid < StandardNames.CffStrings.Length) return StandardNames.CffStrings[sid];
        var s = _strings.Item(_d, sid - StandardNames.CffStrings.Length);
        return Encoding.Latin1.GetString(s);
    }

    /// <summary>The first glyph with this name, 0 when there is none or the font is CID-keyed.</summary>
    public int GlyphForName(string name)
    {
        if (IsCid) return 0;
        if (_nameToGlyph == null)
        {
            var map = new Dictionary<string, int>(_charset.Length);
            for (var g = 0; g < _charset.Length; g++)
                if (GlyphName(g) is { } n) map.TryAdd(n, g);
            _nameToGlyph = map;
        }
        return _nameToGlyph.GetValueOrDefault(name);
    }

    /// <summary>
    /// Glyph for a CID. A CID-keyed font maps through its charset; a name-keyed font used as a CIDFont
    /// takes the CID as the glyph index (ISO 32000-1 9.7.4.2). 0 when absent.
    /// </summary>
    public int GlyphForCid(int cid)
    {
        if (!IsCid) return cid >= 0 && cid < GlyphCount ? cid : 0;
        return SidToGlyph().GetValueOrDefault(cid);
    }

    /// <summary>The CID of a glyph in a CID-keyed font; the glyph index itself otherwise.</summary>
    public int CidForGlyph(int glyphId) => IsCid && glyphId >= 0 && glyphId < _charset.Length ? _charset[glyphId] : glyphId;

    /// <summary>Advance width of the glyph in font units, taken from its charstring. 0 for a glyph out of range.</summary>
    public double GetWidth(int glyphId) => glyphId < 0 || glyphId >= GlyphCount ? 0 : Interpret(glyphId, true, true).Width;

    /// <summary>The glyph's outline in font units (cubic curves), null for a glyph out of range. A broken charstring gives what was drawn before it broke.</summary>
    public GlyphOutline? GetOutline(int glyphId) =>
        glyphId < 0 || glyphId >= GlyphCount ? null : Interpret(glyphId, false, true).Outline;

    internal CffGlyph Interpret(int glyphId, bool widthOnly, bool allowSeac)
    {
        var fd = FdSelect != null && glyphId < FdSelect.Length ? FdSelect[glyphId] : 0;
        var priv = Privates[Math.Min(fd, Privates.Length - 1)];
        return new CffInterpreter(this, priv, widthOnly, allowSeac).Run(glyphId);
    }
}

internal readonly record struct CffGlyph(GlyphOutline Outline, double Width);

internal readonly struct CffPrivate(CffIndex subrs, double defaultWidth, double nominalWidth)
{
    public readonly CffIndex Subrs = subrs;
    public readonly double DefaultWidth = defaultWidth;
    public readonly double NominalWidth = nominalWidth;

    /// <summary>Reads the Private DICT a font DICT points to, with its local subroutines.</summary>
    public static CffPrivate Read(byte[] d, CffDict fontDict)
    {
        var p = fontDict.Numbers(18);
        if (p is not { Length: 2 } || p[1] <= 0 || p[1] >= d.Length) return new CffPrivate(default, 0, 0);
        var at = (int)p[1];
        var dict = CffDict.Parse(d.AsSpan(at, (int)Math.Min(Math.Min(Math.Max(p[0], 0), d.Length - at), CffFont.MaxDictSize)));
        CffIndex subrs = default;
        var subrsAt = dict.Number(19, 0);
        if (subrsAt > 0 && at + subrsAt < d.Length) CffIndex.TryRead(d, at + (int)subrsAt, out subrs);
        return new CffPrivate(subrs, dict.Number(20, 0), dict.Number(21, 0));
    }
}

internal readonly struct CffIndex
{
    private readonly int _offsetsAt;
    private readonly int _offSize;
    private readonly int _dataBase;

    private CffIndex(int count, int offSize, int offsetsAt, int dataBase, int end)
    {
        Count = count;
        _offSize = offSize;
        _offsetsAt = offsetsAt;
        _dataBase = dataBase;
        End = end;
    }

    public int Count { get; }

    /// <summary>Position after the INDEX, where the next structure starts.</summary>
    public int End { get; }

    public static bool TryRead(byte[] d, int pos, out CffIndex index)
    {
        index = default;
        if (pos < 0 || pos > d.Length - 2) return false;
        var count = U16(d, pos);
        if (count == 0)
        {
            index = new CffIndex(0, 1, pos + 2, pos + 2, pos + 2);
            return true;
        }
        var offSize = U8(d, pos + 2);
        if (offSize is < 1 or > 4) return false;
        var offsetsAt = pos + 3;
        var dataBase = offsetsAt + (count + 1) * offSize - 1;
        if (dataBase >= d.Length) return false;
        var last = Offset(d, offsetsAt, offSize, count);
        if (last < 1 || last > d.Length - dataBase) return false;
        index = new CffIndex(count, offSize, offsetsAt, dataBase, dataBase + last);
        return true;
    }

    private static int Offset(byte[] d, int at, int size, int i)
    {
        var v = 0L;
        for (var k = 0; k < size; k++) v = (v << 8) | (long)U8(d, at + i * size + k);
        return v > int.MaxValue ? int.MaxValue : (int)v;
    }

    public ReadOnlySpan<byte> Item(byte[] d, int i)
    {
        if (i < 0 || i >= Count) return default;
        var start = Offset(d, _offsetsAt, _offSize, i);
        var end = Offset(d, _offsetsAt, _offSize, i + 1);
        if (start < 1 || end < start || end > End - _dataBase) return default;
        return d.AsSpan(_dataBase + start, end - start);
    }
}

/// <summary>A parsed DICT: the operands of each operator, a two-byte operator 12 n keyed as 1200 + n.</summary>
internal sealed class CffDict
{
    private const int MaxOperands = 48;
    private readonly Dictionary<int, double[]> _entries = [];

    public static CffDict Parse(ReadOnlySpan<byte> d)
    {
        var dict = new CffDict();
        Span<double> operands = stackalloc double[MaxOperands];
        var n = 0;
        for (var p = 0; p < d.Length;)
        {
            var b = d[p++];
            if (b <= 21)
            {
                int op = b;
                if (b == 12) op = 1200 + U8(d, p++);
                dict._entries[op] = operands[..n].ToArray();
                n = 0;
                continue;
            }

            double v;
            if (b == 28)
            {
                v = I16(d, p);
                p += 2;
            }
            else if (b == 29)
            {
                v = (int)U32(d, p);
                p += 4;
            }
            else if (b == 30) v = ReadReal(d, ref p);
            else if (b >= 32 && b <= 246) v = b - 139;
            else if (b >= 247 && b <= 250) v = (b - 247) * 256 + U8(d, p++) + 108;
            else if (b >= 251 && b <= 254) v = -(b - 251) * 256 - U8(d, p++) - 108;
            else continue;
            if (n < MaxOperands) operands[n++] = v;
        }
        return dict;
    }

    private static double ReadReal(ReadOnlySpan<byte> d, ref int p)
    {
        var sb = new StringBuilder();
        while (p < d.Length)
        {
            var b = d[p++];
            for (var half = 0; half < 2; half++)
            {
                var nibble = half == 0 ? b >> 4 : b & 15;
                switch (nibble)
                {
                    case <= 9: sb.Append((char)('0' + nibble)); break;
                    case 10: sb.Append('.'); break;
                    case 11: sb.Append('E'); break;
                    case 12: sb.Append("E-"); break;
                    case 14: sb.Append('-'); break;
                    case 15: return double.TryParse(sb.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : 0;
                }
            }
        }
        return 0;
    }

    public bool Has(int op) => _entries.ContainsKey(op);

    public double[]? Numbers(int op) => _entries.GetValueOrDefault(op);

    public double Number(int op, double fallback) => _entries.TryGetValue(op, out var v) && v.Length > 0 ? v[0] : fallback;
}
