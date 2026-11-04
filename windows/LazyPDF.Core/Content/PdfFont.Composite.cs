namespace LazyPDF.Core;

// Type 0 fonts: a CMap cuts the string into codes and gives each a CID, the descendant CIDFont
// gives the CID a width and a glyph (9.7).
public sealed partial class PdfFont
{
    private const int MaxCid = 0xFFFF;
    private const int MaxWidthEntries = 300_000;

    // Adobe's character collections, and the Unicode CMaps that reach their CIDs (the half-width one
    // is where the single-byte codes of the Shift-JIS CMaps go). The vertical ones come last: they
    // add the CIDs of the vertical forms, which the horizontal maps never reach.
    private static readonly Dictionary<string, string[]> UnicodeCMaps = new()
    {
        ["Japan1"] = ["UniJIS-UCS2-H", "UniJIS-UCS2-HW-H", "UniJIS-UCS2-V"],
        ["GB1"] = ["UniGB-UCS2-H", "UniGB-UCS2-V"],
        ["CNS1"] = ["UniCNS-UCS2-H", "UniCNS-UCS2-V"],
        ["Korea1"] = ["UniKS-UCS2-H", "UniKS-UCS2-V"],
    };

    private static readonly Dictionary<string, Lazy<Dictionary<int, int>>> CidToUnicode =
        UnicodeCMaps.ToDictionary(p => p.Key, p => new Lazy<Dictionary<int, int>>(() => Invert(p.Value.Select(CMap.Predefined))));

    private CMap _cmap = CMap.Predefined("Identity-H");
    private PdfDictionary? _cidFont;
    private string _ordering = "";
    private double _defaultWidth = 1000;
    private double _defaultOriginY = 880;
    private double _defaultAdvance = -1000;
    private readonly Dictionary<int, double> _cidWidths = [];
    private readonly Dictionary<int, (double Advance, double X, double Y)> _cidVertical = [];
    private ushort[]? _cidToGid;
    private bool _cidToGidLoaded;
    private readonly Dictionary<long, FontChar> _composite = [];

    private static Dictionary<int, int> Invert(IEnumerable<CMap> unicodeMaps)
    {
        var map = new Dictionary<int, int>();
        foreach (var unicodeMap in unicodeMaps)
        {
            for (int code = 0x20; code <= 0xFFFF; code++)
            {
                if (unicodeMap.CidOf(code, 2) is { } cid and > 0) map.TryAdd(cid, code);
            }
        }
        return map;
    }

    private void InitializeComposite(PdfDictionary cidFont)
    {
        _cidFont = cidFont;
        _cmap = _document.Resolve(Dictionary["Encoding"]) switch
        {
            PdfName name => CMap.Predefined(name.Value),
            PdfStream stream => TryReadCMap(stream) ?? _cmap,
            _ => _cmap,
        };
        IsVertical = _cmap.IsVertical;
        if (_document.Dict(cidFont, "CIDSystemInfo") is { } info && _document.Resolve(info["Ordering"]) is PdfString ordering)
        {
            _ordering = System.Text.Encoding.Latin1.GetString(ordering.Bytes);
        }
        _defaultWidth = _document.Number(cidFont, "DW") ?? 1000;
        if (_document.Array(cidFont, "DW2") is { Items.Count: >= 2 } dw2
            && _document.Resolve(dw2.Items[0]) is PdfNumber vy && _document.Resolve(dw2.Items[1]) is PdfNumber w1)
        {
            _defaultOriginY = vy.Value;
            _defaultAdvance = w1.Value;
        }
        if (_document.Array(cidFont, "W") is { } w) ReadWidths(w);
        if (_document.Array(cidFont, "W2") is { } w2) ReadVerticalMetrics(w2);
    }

    private CMap? TryReadCMap(PdfStream stream)
    {
        try
        {
            return ReadCMap(stream);
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    private CMap ReadCMap(PdfStream stream)
    {
        CMap? parent = _document.Resolve(stream.Dictionary["UseCMap"]) switch
        {
            PdfName name => CMap.Predefined(name.Value),
            PdfStream inner when !ReferenceEquals(inner, stream) => CMap.Parse(_document.Data(inner, 16 << 20)),
            _ => null,
        };
        var map = CMap.Parse(_document.Data(stream, 16 << 20), parent);
        return map;
    }

    private double? Num(PdfObject? value) => _document.Resolve(value) is PdfNumber { Value: var v } && double.IsFinite(v) ? v : null;

    // 9.7.4.3: "c [w1 w2 ...]" or "cfirst clast w".
    private void ReadWidths(PdfArray array)
    {
        var items = array.Items;
        int budget = MaxWidthEntries;
        for (int i = 0; i < items.Count && budget > 0;)
        {
            if (Num(items[i]) is not { } first) { i++; continue; }
            if (i + 1 < items.Count && _document.Resolve(items[i + 1]) is PdfArray list)
            {
                for (int k = 0; k < list.Items.Count && first + k <= MaxCid && budget-- > 0; k++)
                {
                    if (Num(list.Items[k]) is { } width) _cidWidths[(int)first + k] = width;
                }
                i += 2;
            }
            else if (i + 2 < items.Count)
            {
                if (Num(items[i + 1]) is { } last && Num(items[i + 2]) is { } width)
                {
                    for (long c = (long)Math.Max(first, 0); c <= Math.Min(last, MaxCid) && budget-- > 0; c++) _cidWidths[(int)c] = width;
                }
                i += 3;
            }
            else break;
        }
    }

    // 9.7.4.3: "c [w1 vx vy ...]" or "cfirst clast w1 vx vy".
    private void ReadVerticalMetrics(PdfArray array)
    {
        var items = array.Items;
        int budget = MaxWidthEntries;
        for (int i = 0; i < items.Count && budget > 0;)
        {
            if (Num(items[i]) is not { } first) { i++; continue; }
            if (i + 1 < items.Count && _document.Resolve(items[i + 1]) is PdfArray list)
            {
                for (int k = 0; k + 2 < list.Items.Count && first + k / 3 <= MaxCid && budget-- > 0; k += 3)
                {
                    if (Num(list.Items[k]) is { } a && Num(list.Items[k + 1]) is { } x && Num(list.Items[k + 2]) is { } y)
                        _cidVertical[(int)first + k / 3] = (a, x, y);
                }
                i += 2;
            }
            else if (i + 4 < items.Count)
            {
                if (Num(items[i + 1]) is { } last && Num(items[i + 2]) is { } a && Num(items[i + 3]) is { } x && Num(items[i + 4]) is { } y)
                {
                    for (long c = (long)Math.Max(first, 0); c <= Math.Min(last, MaxCid) && budget-- > 0; c++) _cidVertical[(int)c] = (a, x, y);
                }
                i += 5;
            }
            else break;
        }
    }

    private int ReadComposite(ReadOnlySpan<byte> bytes, out FontChar character)
    {
        int code = _cmap.NextCode(bytes, out int length);
        if (length <= 0 || length > bytes.Length)
        {
            length = 1;
            code = bytes[0];
        }
        long key = ((long)length << 32) | (uint)code;
        if (_composite.TryGetValue(key, out character)) return length;
        int cid = _cmap.CidOf(code, length) ?? 0;
        double width = _cidWidths.TryGetValue(cid, out double w) ? w : _defaultWidth;
        var (advance, originX, originY) = _cidVertical.TryGetValue(cid, out var v) ? v : (_defaultAdvance, width / 2, _defaultOriginY);
        character = new FontChar(code, length, cid, width, CompositeUnicode(code, length, cid), length == 1 && code == 32, advance, originX, originY);
        if (_composite.Count < MaxCached) _composite[key] = character;
        return length;
    }

    private string? CompositeUnicode(int code, int length, int cid)
    {
        if (MappedText(code, length) is { } mapped) return mapped;
        if (_cmap.Name is { } name && name.StartsWith("Uni", StringComparison.Ordinal) && _cmap.UnicodeOf(code, length) is { Length: > 0 } direct) return direct;
        if (cid == 0) return null;
        if (CidToUnicode.TryGetValue(_ordering, out var table) && table.Value.TryGetValue(cid, out int codePoint)) return char.ConvertFromUtf32(codePoint);
        if (Program is not { } program) return null;
        if (program.TrueType is { Cff: null })
        {
            return GlyphOf(cid) is var gid && gid > 0 ? program.UnicodeOf(gid) : null;
        }
        if (program.Cff is { } cff)
        {
            int gid = cff.IsCid ? cff.GlyphForCid(cid) : cid;
            return gid > 0 && cff.GlyphName(gid) is { } glyphName ? GlyphList.UnicodeOf(glyphName) : null;
        }
        return null;
    }

    // /CIDToGIDMap of a CIDFontType2: identity unless a stream says otherwise (9.7.4.2).
    private int GlyphOf(int cid)
    {
        if (!_cidToGidLoaded)
        {
            _cidToGidLoaded = true;
            if (_document.Resolve(_cidFont?["CIDToGIDMap"]) is PdfStream map)
            {
                try
                {
                    byte[] data = _document.Data(map, 1 << 18);
                    _cidToGid = new ushort[data.Length / 2];
                    for (int i = 0; i < _cidToGid.Length; i++) _cidToGid[i] = (ushort)(data[2 * i] << 8 | data[2 * i + 1]);
                }
                catch (PdfReadException)
                {
                }
            }
        }
        if (_cidToGid is null) return cid;
        return cid < _cidToGid.Length ? _cidToGid[cid] : 0;
    }
}
