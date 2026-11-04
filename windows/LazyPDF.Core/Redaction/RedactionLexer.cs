using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// Reads content bytes again with none of the repairs <see cref="ContentParser"/> makes. What it refuses is what two
/// viewers may split differently: comments, stray delimiters, numbers spelled any way but ISO 32000-1 7.3.3 spells them,
/// operands left over at the end, and an inline image dictionary (8.9.7) with anything in it but its own keys.
/// </summary>
internal sealed class RedactionLexer(byte[] data, IReadOnlyDictionary<int, int> imageEnds, HashSet<int> breaks)
{
    private const int MaxDepth = 32;
    private const int MaxOperands = 256;
    private const int MaxDigits = 10;

    // Inline image keys with their abbreviations (Table 93).
    private static readonly Dictionary<string, string> ImageKeys = new()
    {
        ["BPC"] = "BitsPerComponent", ["BitsPerComponent"] = "BitsPerComponent", ["CS"] = "ColorSpace", ["ColorSpace"] = "ColorSpace",
        ["D"] = "Decode", ["Decode"] = "Decode", ["DP"] = "DecodeParms", ["DecodeParms"] = "DecodeParms", ["F"] = "Filter", ["Filter"] = "Filter",
        ["H"] = "Height", ["Height"] = "Height", ["IM"] = "ImageMask", ["ImageMask"] = "ImageMask", ["I"] = "Interpolate", ["Interpolate"] = "Interpolate",
        ["W"] = "Width", ["Width"] = "Width", ["Intent"] = "Intent",
    };

    private enum Read { Value, Keyword, Bad }

    private int _at;

    private static bool IsWhite(byte c) => c is 0 or 9 or 10 or 12 or 13 or 32;

    private static bool IsDelimiter(byte c) => c is (byte)'(' or (byte)')' or (byte)'<' or (byte)'>' or (byte)'[' or (byte)']' or (byte)'{' or (byte)'}' or (byte)'/' or (byte)'%';

    private static bool IsRegular(byte c) => !IsWhite(c) && !IsDelimiter(c);

    /// <summary>
    /// Whether <paramref name="data"/> is made only of whole tokens. <paramref name="imageEnds"/> gives, for each inline image
    /// by the offset of its BI, the offset after its EI. <paramref name="breaks"/> are the offsets of the separators put between
    /// content streams (7.8.2): a token, a string or an image may not run across one, nor may two characters that a viewer
    /// reading the streams end to end would join into one token. A dictionary or array may stay open, and operands may wait for
    /// their operator in the next stream.
    /// </summary>
    public static bool Whole(byte[] data, IReadOnlyDictionary<int, int> imageEnds, IReadOnlyList<int> breaks) =>
        new RedactionLexer(data, imageEnds, [.. breaks]).Run();

    private bool Run()
    {
        foreach (int b in breaks)
        {
            if (b > 0 && b + 1 < data.Length && IsRegular(data[b - 1]) && IsRegular(data[b + 1])) return false;
        }
        int pending = 0;
        while (true)
        {
            Skip();
            if (_at >= data.Length) return pending == 0;
            int start = _at;
            switch (Value(0))
            {
                case Read.Bad:
                    return false;
                case Read.Value:
                    if (++pending > MaxOperands) return false;
                    break;
                case Read.Keyword:
                    string word = Word();
                    if (!RedactionSyntax.Knows(word)) return false;
                    if (word == "BI")
                    {
                        if (pending > 0 || !imageEnds.TryGetValue(start, out int end) || !Dictionary() || end < _at + 1 || end > data.Length) return false;
                        if (breaks.Any(b => b >= _at && b < end)) return false;
                        _at = end;
                    }
                    pending = 0;
                    break;
            }
        }
    }

    private void Skip()
    {
        while (_at < data.Length && IsWhite(data[_at])) _at++;
    }

    private string Word()
    {
        int start = _at;
        while (_at < data.Length && IsRegular(data[_at])) _at++;
        return Encoding.Latin1.GetString(data, start, _at - start);
    }

    // One operand at the position, or a keyword (nothing consumed), or something that cannot be read.
    private Read Value(int depth)
    {
        if (depth > MaxDepth) return Read.Bad;
        byte c = data[_at];
        switch (c)
        {
            case (byte)'/':
                _at++;
                while (_at < data.Length && IsRegular(data[_at])) _at++;
                return Read.Value;
            case (byte)'(':
                return Literal() ? Read.Value : Read.Bad;
            case (byte)'<' when _at + 1 < data.Length && data[_at + 1] == '<':
                return Container(depth, true) ? Read.Value : Read.Bad;
            case (byte)'<':
                return Hex() ? Read.Value : Read.Bad;
            case (byte)'[':
                return Container(depth, false) ? Read.Value : Read.Bad;
        }
        if (IsDelimiter(c)) return Read.Bad;
        int save = _at;
        string word = Word();
        if (word is "true" or "false" or "null") return Read.Value;
        if (c is (>= (byte)'0' and <= (byte)'9') or (byte)'+' or (byte)'-' or (byte)'.') return IsNumber(word) ? Read.Value : Read.Bad;
        _at = save;
        return Read.Keyword;
    }

    // Digits with at most one point and one leading sign; no exponent, and an integer part that fits 32 bits (Annex C).
    private static bool IsNumber(string text)
    {
        int i = text.Length > 0 && text[0] is '+' or '-' ? 1 : 0;
        int digits = 0, points = 0, whole = 0;
        for (; i < text.Length; i++)
        {
            if (text[i] == '.' && ++points == 1) continue;
            if (text[i] is < '0' or > '9') return false;
            digits++;
            if (points == 0) whole++;
        }
        if (digits == 0 || whole > MaxDigits) return false;
        return whole < MaxDigits || long.Parse(text.TrimStart('+', '-').Split('.')[0]) <= int.MaxValue;
    }

    private bool Literal()
    {
        int depth = 0;
        for (; _at < data.Length; _at++)
        {
            if (breaks.Contains(_at)) return false;
            switch (data[_at])
            {
                case (byte)'\\':
                    _at++;
                    break;
                case (byte)'(':
                    depth++;
                    break;
                case (byte)')' when --depth == 0:
                    _at++;
                    return true;
            }
        }
        return false;
    }

    private bool Hex()
    {
        for (_at++; _at < data.Length; _at++)
        {
            byte c = data[_at];
            if (c == '>')
            {
                _at++;
                return true;
            }
            if (breaks.Contains(_at) || !(IsWhite(c) || c is (>= (byte)'0' and <= (byte)'9') or (>= (byte)'a' and <= (byte)'f') or (>= (byte)'A' and <= (byte)'F'))) return false;
        }
        return false;
    }

    // An array holds values; a dictionary holds a name and a value in turn.
    private bool Container(int depth, bool dictionary)
    {
        _at += dictionary ? 2 : 1;
        while (true)
        {
            Skip();
            if (_at >= data.Length) return false;
            if (data[_at] == (dictionary ? '>' : ']'))
            {
                if (dictionary && !(_at + 1 < data.Length && data[_at + 1] == '>')) return false;
                _at += dictionary ? 2 : 1;
                return true;
            }
            if (dictionary)
            {
                if (data[_at] != '/' || Value(depth + 1) != Read.Value) return false;
                Skip();
                if (_at >= data.Length || Value(depth + 1) != Read.Value) return false;
            }
            else if (Value(depth + 1) != Read.Value)
            {
                return false;
            }
        }
    }

    // The keys of the image, once each under either spelling, up to ID and the single white space byte after it.
    private bool Dictionary()
    {
        var seen = new HashSet<string>();
        while (true)
        {
            Skip();
            if (_at >= data.Length) return false;
            if (data[_at] != '/')
            {
                if (Word() != "ID") return false;
                return _at < data.Length && IsWhite(data[_at]);
            }
            int start = ++_at;
            while (_at < data.Length && IsRegular(data[_at])) _at++;
            string key = Encoding.Latin1.GetString(data, start, _at - start);
            if (!ImageKeys.TryGetValue(key, out string? canonical) || !seen.Add(canonical)) return false;
            Skip();
            if (_at >= data.Length || Value(0) != Read.Value) return false;
        }
    }
}
