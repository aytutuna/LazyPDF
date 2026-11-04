using System.Globalization;

namespace LazyPDF.Core;

/// <summary>
/// A Type 1 font program (Adobe Type 1 Font Format) in PFA, PFB or the bare form of a PDF's FontFile:
/// the clear-text header, then the eexec-encrypted private part with Subrs and CharStrings.
/// </summary>
public sealed class Type1Font
{
    private const int MaxGlyphs = 65536;
    private const int MaxSubrs = 65536;

    private readonly Dictionary<string, byte[]> _charStrings = new(StringComparer.Ordinal);
    private readonly List<string> _names = [];
    private byte[]?[] _subrs = [];

    private Type1Font()
    {
    }

    public string FontName { get; private set; } = "";

    /// <summary>FontMatrix, 0.001 0 0 0.001 0 0 when the header has none.</summary>
    public double[] FontMatrix { get; private set; } = [0.001, 0, 0, 0.001, 0, 0];

    public GlyphBounds? FontBounds { get; private set; }

    /// <summary>The built-in encoding: the glyph name of each code, null where none is assigned.</summary>
    public string?[] BuiltInEncoding { get; private set; } = new string?[256];

    /// <summary>Glyph names in file order.</summary>
    public IReadOnlyList<string> GlyphNames => _names;

    internal byte[]?[] Subrs => _subrs;

    public bool HasGlyph(string name) => _charStrings.ContainsKey(name);

    internal byte[]? CharString(string name) => _charStrings.GetValueOrDefault(name);

    /// <summary>Advance width of the named glyph in font units, 0 when the glyph does not exist.</summary>
    public double GetWidth(string name) => Run(name, true) is { } g ? g.Width : 0;

    /// <summary>
    /// Outline of the named glyph in font units (cubic curves), null when it does not exist.
    /// Flex sequences become two curves and accented characters (seac) are composed.
    /// </summary>
    public GlyphOutline? GetOutline(string name) => Run(name, true)?.Outline;

    internal Type1Glyph? Run(string name, bool allowSeac) =>
        _charStrings.ContainsKey(name) ? new Type1Interpreter(this, allowSeac).Run(name) : null;

    /// <summary>Parses a PFA, PFB or FontFile stream; null when no glyph can be found in it.</summary>
    public static Type1Font? TryParse(byte[] data)
    {
        SplitSegments(data, out var clear, out var encrypted);
        var font = new Type1Font();
        font.ReadHeader(clear);

        byte[] priv;
        if (encrypted.Length > 0) priv = Decrypt(encrypted, 55665, 4);
        else priv = clear;
        font.ReadPrivate(priv);
        return font._charStrings.Count > 0 ? font : null;
    }

    private static void SplitSegments(byte[] data, out byte[] clear, out byte[] encrypted)
    {
        if (data.Length > 6 && data[0] == 0x80)
        {
            using var c = new MemoryStream();
            using var e = new MemoryStream();
            var p = 0;
            while (p + 6 <= data.Length && data[p] == 0x80 && data[p + 1] is 1 or 2)
            {
                var len = BitConverter.ToUInt32(data, p + 2);
                var n = (int)Math.Min(len, (uint)(data.Length - p - 6));
                if (data[p + 1] == 1) (e.Length == 0 ? c : Stream.Null).Write(data, p + 6, n);
                else e.Write(data, p + 6, n);
                p += 6 + n;
            }
            clear = c.ToArray();
            encrypted = e.ToArray();
            return;
        }

        var at = data.AsSpan().IndexOf("eexec"u8);
        if (at < 0)
        {
            clear = data;
            encrypted = [];
            return;
        }
        var start = at + 5;
        clear = data[..start];
        while (start < data.Length && data[start] is (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n') start++;
        var rest = data.AsSpan(start);
        encrypted = IsHex(rest) ? DecodeHex(rest) : rest.ToArray();
    }

    private static bool IsHex(ReadOnlySpan<byte> d)
    {
        if (d.Length < 4) return false;
        for (var i = 0; i < 4; i++)
            if (!Uri.IsHexDigit((char)d[i])) return false;
        return true;
    }

    private static byte[] DecodeHex(ReadOnlySpan<byte> d)
    {
        var result = new List<byte>(d.Length / 2);
        var high = -1;
        foreach (var b in d)
        {
            if (b is (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n') continue;
            if (!Uri.IsHexDigit((char)b)) break;
            var v = Uri.FromHex((char)b);
            if (high < 0) high = v;
            else
            {
                result.Add((byte)(high << 4 | v));
                high = -1;
            }
        }
        return result.ToArray();
    }

    /// <summary>The eexec and charstring cipher (Type 1 Font Format, chapter 7); the first <paramref name="skip"/> bytes are random padding.</summary>
    internal static byte[] Decrypt(ReadOnlySpan<byte> cipher, ushort key, int skip)
    {
        if (cipher.Length <= skip) return [];
        var plain = new byte[cipher.Length - skip];
        var r = key;
        for (var i = 0; i < cipher.Length; i++)
        {
            var c = cipher[i];
            if (i >= skip) plain[i - skip] = (byte)(c ^ (r >> 8));
            r = (ushort)((c + r) * 52845 + 22719);
        }
        return plain;
    }

    private void ReadHeader(byte[] clear)
    {
        var s = new Scanner(clear);
        if (s.SeekAfter("/FontName") && s.Next() is { } name && name.StartsWith('/')) FontName = name[1..];

        s = new Scanner(clear);
        if (s.SeekAfter("/FontMatrix") && s.Numbers() is { Length: 6 } m) FontMatrix = m;

        s = new Scanner(clear);
        if (s.SeekAfter("/FontBBox") && s.Numbers() is { Length: 4 } b) FontBounds = new GlyphBounds(b[0], b[1], b[2], b[3]);

        s = new Scanner(clear);
        while (s.SeekAfter("/Encoding"))
            if (ReadEncoding(s)) break;
    }

    /// <summary>False when the key was not the encoding entry (a string in the notice can hold the same word).</summary>
    private bool ReadEncoding(Scanner s)
    {
        var first = s.Next();
        if (first == "StandardEncoding")
        {
            Array.Copy(StandardNames.StandardEncoding, BuiltInEncoding, 256);
            return true;
        }
        if (!int.TryParse(first, out _)) return false;
        for (var guard = 0; guard < 8192; guard++)
        {
            var t = s.Next();
            if (t == null || t == "def") break;
            if (t != "dup") continue;
            var code = s.Next();
            var name = s.Next();
            if (code != null && name != null && name.StartsWith('/') && ParseCode(code) is { } c and >= 0 and < 256)
                BuiltInEncoding[c] = name[1..];
        }
        return true;
    }

    private static int? ParseCode(string token)
    {
        var hash = token.IndexOf('#');
        if (hash > 0)
            return int.TryParse(token[..hash], out var radix) && radix is >= 2 and <= 36
                ? Radix(token[(hash + 1)..], radix)
                : null;
        return int.TryParse(token, NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : null;
    }

    private static int? Radix(string digits, int radix)
    {
        var v = 0;
        foreach (var ch in digits)
        {
            var d = char.IsAsciiDigit(ch) ? ch - '0' : char.IsAsciiLetter(ch) ? char.ToLowerInvariant(ch) - 'a' + 10 : 99;
            if (d >= radix) return null;
            v = v * radix + d;
            if (v > 100000) return null;
        }
        return v;
    }

    private void ReadPrivate(byte[] d)
    {
        var lenIV = 4;
        var s = new Scanner(d);
        if (s.SeekAfter("/lenIV") && int.TryParse(s.Next(), out var iv) && iv is >= -1 and <= 64) lenIV = iv;

        s = new Scanner(d);
        if (s.SeekAfter("/Subrs") && int.TryParse(s.Next(), out var count) && count is > 0 and <= MaxSubrs)
        {
            _subrs = new byte[]?[count];
            ReadSubrs(s, lenIV);
        }

        s = new Scanner(d);
        if (s.SeekAfter("/CharStrings")) ReadCharStrings(s, lenIV);
    }

    private void ReadSubrs(Scanner s, int lenIV)
    {
        while (s.Next() is { } t)
        {
            if (t.StartsWith('/')) break;
            if (t != "dup") continue;
            if (!int.TryParse(s.Next(), out var index)) break;
            var len = s.NextInt();
            if (s.Next() == null || s.Binary(len) is not { } bytes) break;
            if (index >= 0 && index < _subrs.Length) _subrs[index] = Unlock(bytes, lenIV);
        }
    }

    private void ReadCharStrings(Scanner s, int lenIV)
    {
        while (s.Next() is { } t && t != "end" && _names.Count < MaxGlyphs)
        {
            if (!t.StartsWith('/')) continue;
            var len = s.NextInt();
            if (s.Next() == null || s.Binary(len) is not { } bytes) break;
            var name = t[1..];
            if (_charStrings.TryAdd(name, Unlock(bytes, lenIV))) _names.Add(name);
        }
    }

    private static byte[] Unlock(byte[] cipher, int lenIV) => lenIV < 0 ? cipher : Decrypt(cipher, 4330, lenIV);

    /// <summary>A PostScript token reader over the font text; binary charstrings are skipped by length.</summary>
    private sealed class Scanner(byte[] d)
    {
        private int _p;

        private static bool IsSpace(byte b) => b is 0 or 9 or 10 or 12 or 13 or 32;

        private static bool IsDelimiter(byte b) => b is (byte)'(' or (byte)')' or (byte)'<' or (byte)'>' or (byte)'[' or (byte)']' or (byte)'{' or (byte)'}' or (byte)'/' or (byte)'%';

        public bool SeekAfter(string key)
        {
            var at = d.AsSpan(_p).IndexOf(System.Text.Encoding.ASCII.GetBytes(key));
            if (at < 0) return false;
            _p += at + key.Length;
            return true;
        }

        public string? Next()
        {
            while (_p < d.Length)
            {
                if (IsSpace(d[_p])) _p++;
                else if (d[_p] == '%')
                {
                    while (_p < d.Length && d[_p] is not (10 or 13)) _p++;
                }
                else break;
            }
            if (_p >= d.Length) return null;

            var start = _p++;
            if (d[start] == '/')
                while (_p < d.Length && !IsSpace(d[_p]) && !IsDelimiter(d[_p])) _p++;
            else if (!IsDelimiter(d[start]))
                while (_p < d.Length && !IsSpace(d[_p]) && !IsDelimiter(d[_p])) _p++;
            return System.Text.Encoding.Latin1.GetString(d, start, _p - start);
        }

        public int NextInt() => int.TryParse(Next(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var v) ? v : -1;

        /// <summary>The bytes after the RD token: one separator, then <paramref name="length"/> bytes. Null when they do not fit.</summary>
        public byte[]? Binary(int length)
        {
            if (length < 0 || length > d.Length - _p - 1) return null;
            var bytes = d.AsSpan(_p + 1, length).ToArray();
            _p += 1 + length;
            return bytes;
        }

        /// <summary>Numbers of a [ ... ] or { ... } list, null when the list is missing or holds anything else.</summary>
        public double[]? Numbers()
        {
            if (Next() is not ("[" or "{")) return null;
            var list = new List<double>();
            while (Next() is { } t && t is not ("]" or "}"))
            {
                if (!double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) return null;
                if (list.Count >= 16) return null;
                list.Add(v);
            }
            return list.ToArray();
        }
    }
}

internal readonly record struct Type1Glyph(GlyphOutline Outline, double Width);
