using System.Collections.Concurrent;

namespace LazyPDF.Core;

/// <summary>
/// A CMap (ISO 32000-1 9.7.5, 9.10.3): the codespace that cuts a string into character codes, and
/// what the codes map to, character ids for a composite font or text for a ToUnicode map. Codes are at
/// most four bytes; a four-byte code above 0x7FFFFFFF is a negative int.
/// </summary>
public sealed class CMap
{
    const int MaxCodespaces = 100;
    const int MaxEntries = 1_000_000;

    internal readonly record struct Codespace(int Length, uint Lo, uint Hi);

    static readonly ConcurrentDictionary<string, CMap> Predefineds = new();

    internal readonly CodeRanges<int> Cids = new();
    internal readonly CodeRanges<int> Notdefs = new();
    internal readonly CodeRanges<string> Texts = new();
    internal readonly List<Codespace> SpaceList = [];

    Codespace[] _spaces = [];
    CMap? _parent;
    bool _identity;
    bool _codesAreUnicode;

    CMap()
    {
    }

    /// <summary>The CMapName, when the file gives one.</summary>
    public string? Name { get; internal set; }

    /// <summary>Writing mode 1: glyphs advance downwards (/WMode).</summary>
    public bool IsVertical { get; internal set; }

    /// <summary>True for a predefined name this library has no table for; its codes are read as two bytes and its CIDs as the codes.</summary>
    public bool IsFallback { get; private set; }

    internal bool Full => Cids.Count + Notdefs.Count + Texts.Count >= MaxEntries;

    /// <summary>
    /// Reads an embedded CMap or a ToUnicode stream. Malformed parts are skipped and what came before
    /// them kept; the work is linear in the data and at most a million mappings are kept. The stream's
    /// /UseCMap, when it has one, is passed as <paramref name="useCMap"/>; a "usecmap" in the data
    /// names a predefined CMap and takes its place.
    /// </summary>
    public static CMap Parse(byte[] data, CMap? useCMap = null)
    {
        var map = new CMap { _parent = useCMap };
        CMapParser.Run(data, map);
        map.Finish();
        return map;
    }

    /// <summary>
    /// The predefined CMap of that name: Identity-H and Identity-V, and Adobe's CJK ones that map
    /// to CIDs (UniGB-UCS2-H, 90ms-RKSJ-H, ETen-B5-V and the rest of the Japan1, GB1, CNS1 and Korea1 sets).
    /// Any other name gives a two-byte fallback with <see cref="IsFallback"/> set.
    /// </summary>
    public static CMap Predefined(string name)
    {
        if (Predefineds.TryGetValue(name, out var known))
            return known;
        var map = name switch
        {
            "Identity-H" or "Identity-V" => Identity(name),
            _ => Load(name),
        };
        // A name that is none of them comes from the file, so it is not remembered.
        return map is null ? Fallback(name) : Predefineds.GetOrAdd(name, map);
    }

    static CMap Identity(string name)
    {
        var map = new CMap { Name = name, IsVertical = name == "Identity-V", _identity = true };
        map.SpaceList.Add(new Codespace(2, 0, 0xFFFF));
        map.Finish();
        return map;
    }

    static CMap Fallback(string name)
    {
        var map = Identity(name);
        map.IsVertical = name.EndsWith("-V", StringComparison.Ordinal);
        map.IsFallback = true;
        return map;
    }

    static CMap? Load(string name)
    {
        var blob = CMapData.Blob(name);
        if (blob.IsEmpty)
            return null;
        var map = new CMap { Name = name, _codesAreUnicode = name.StartsWith("Uni", StringComparison.Ordinal) };
        CMapParser.ReadPacked(TableBlob.InflateUtf8(blob), map);
        map.Finish();
        return map;
    }

    internal void SetParent(CMap parent) => _parent ??= parent;

    internal void Finish()
    {
        Cids.Freeze();
        Notdefs.Freeze();
        Texts.Freeze();
        if (_parent != null)
            foreach (var s in _parent._spaces)
                if (SpaceList.Count < MaxCodespaces)
                    SpaceList.Add(s);
        if (SpaceList.Count == 0)
        {
            // No codespace given: accept any byte at the lengths the mappings use.
            int mask = Cids.LengthMask | Notdefs.LengthMask | Texts.LengthMask;
            for (int n = 1; n <= 4; n++)
                if ((mask & (1 << n)) != 0)
                    SpaceList.Add(new Codespace(n, 0, n == 4 ? uint.MaxValue : (1u << (8 * n)) - 1));
        }
        _spaces = [.. SpaceList];
    }

    /// <summary>
    /// Cuts the next character code off <paramref name="bytes"/> (ISO 32000-1 9.7.6.3): the shortest
    /// prefix inside a codespace range, ranges of different lengths mixed. Bytes that match no range
    /// are consumed as many as the shortest range that starts like them takes, so the string stays in step.
    /// Gives length 0 for empty input.
    /// </summary>
    public int NextCode(ReadOnlySpan<byte> bytes, out int length)
    {
        if (bytes.IsEmpty)
        {
            length = 0;
            return 0;
        }
        uint code = 0;
        int max = Math.Min(4, bytes.Length);
        for (int n = 1; n <= max; n++)
        {
            code = (code << 8) | bytes[n - 1];
            foreach (var s in _spaces)
                if (s.Length == n && Within(s, code))
                {
                    length = n;
                    return (int)code;
                }
        }

        int take = 0, shortest = 0;
        foreach (var s in _spaces)
        {
            shortest = shortest == 0 ? s.Length : Math.Min(shortest, s.Length);
            int shift = 8 * (s.Length - 1);
            byte first = bytes[0];
            if (first >= ((s.Lo >> shift) & 0xFF) && first <= ((s.Hi >> shift) & 0xFF))
                take = take == 0 ? s.Length : Math.Min(take, s.Length);
        }
        if (take == 0)
            take = shortest == 0 ? 1 : shortest;
        take = Math.Min(take, bytes.Length);
        code = 0;
        for (int i = 0; i < take; i++)
            code = (code << 8) | bytes[i];
        length = take;
        return (int)code;
    }

    static bool Within(Codespace s, uint code)
    {
        for (int i = 0; i < s.Length; i++)
        {
            int shift = 8 * (s.Length - 1 - i);
            uint b = (code >> shift) & 0xFF;
            if (b < ((s.Lo >> shift) & 0xFF) || b > ((s.Hi >> shift) & 0xFF))
                return false;
        }
        return true;
    }

    /// <summary>
    /// The character id of a code, or null when the CMap maps it to none. A code in a notdefrange gives that
    /// range's id. Without the code's length, the shortest length that has a mapping is taken.
    /// </summary>
    public int? CidOf(int code) => CidOf(code, 0);

    /// <summary>The same for a code of known byte length, as <see cref="NextCode"/> reports it.</summary>
    public int? CidOf(int code, int length) => FindCid((uint)code, length, false) ?? FindCid((uint)code, length, true);

    int? FindCid(uint code, int length, bool notdef)
    {
        if (_identity)
            return notdef || code > 0xFFFF ? null : (int)code;
        var table = notdef ? Notdefs : Cids;
        for (int n = Math.Max(length, 1); n <= (length == 0 ? 4 : length); n++)
            if ((table.LengthMask & (1 << n)) != 0 && table.TryFind(n, code, out uint lo, out int cid))
                return notdef ? cid : cid + (int)(code - lo);
        return _parent?.FindCid(code, length, notdef);
    }

    /// <summary>The text a ToUnicode CMap gives a code (a bfchar or bfrange), or null. One code may give several characters.</summary>
    public string? UnicodeOf(int code) => UnicodeOf(code, 0);

    public string? UnicodeOf(int code, int length)
    {
        uint c = (uint)code;
        for (int n = Math.Max(length, 1); n <= (length == 0 ? 4 : length); n++)
            if ((Texts.LengthMask & (1 << n)) != 0 && Texts.TryFind(n, c, out uint lo, out string text))
                return c == lo ? text : text[..^1] + (char)(text[^1] + (c - lo));
        if (_codesAreUnicode)
            return FromUtf16Code(c);
        return _parent?.UnicodeOf(code, length);
    }

    // The Uni*-UCS2 and Uni*-UTF16 CMaps take Unicode itself as the code; UTF-16 pairs fill four bytes.
    static string? FromUtf16Code(uint code)
    {
        if (code <= 0xFFFF)
            return char.IsSurrogate((char)code) ? null : ((char)code).ToString();
        char high = (char)(code >> 16), low = (char)code;
        return char.IsHighSurrogate(high) && char.IsLowSurrogate(low) ? new string([high, low]) : null;
    }
}
