using System.Text;

namespace LazyPDF.Core;

internal readonly record struct Slice(int Start, int End);

// Reads the syntax of ISO 32000-1 7.3 as written and nothing else: no comments, no signs inside numbers, no keys
// twice in a dictionary, no unknown escapes or keywords. Where PdfLexer repairs, this stops, so the bytes that pass
// mean the same to every reader. It never throws; a method that returns false leaves Pos where it gave up.
internal sealed class StrictReader(byte[] data, int end)
{
    private const int MaxDepth = 64;
    private const int MaxNumber = PdfDocument.MaxObjectNumber;

    public int Pos { get; set; }

    /// <summary>
    /// Set when reading the signed revision, which is a conforming file rather than an update to be placed exactly: a
    /// stream's /Length may be a reference, this finds the number it holds, and a backslash before a character that
    /// needs none is ignored (7.3.4.2).
    /// </summary>
    public Func<int, long?>? Lengths { get; init; }

    public bool AtEnd => Pos >= end;

    /// <summary>An indirect object: its place, and for a dictionary the span of each top-level value.</summary>
    public sealed record Indirect(int Number, int Generation, int Start, int End, Dictionary<string, Slice>? Keys, bool IsStream);

    public static bool IsSpace(byte b) => b is 0 or 9 or 10 or 12 or 13 or 32;

    private static bool IsDelimiter(byte b) => b is (byte)'(' or (byte)')' or (byte)'<' or (byte)'>' or (byte)'[' or (byte)']' or (byte)'{' or (byte)'}' or (byte)'/' or (byte)'%';

    public void SkipSpace()
    {
        while (Pos < end && IsSpace(data[Pos])) Pos++;
    }

    private bool AtBoundary(int at) => at >= end || IsSpace(data[at]) || IsDelimiter(data[at]);

    /// <summary>The keyword at Pos, which must stand alone: followed by white space, a delimiter or the end.</summary>
    public bool Word(ReadOnlySpan<byte> word)
    {
        if (end - Pos < word.Length || !data.AsSpan(Pos, word.Length).SequenceEqual(word) || !AtBoundary(Pos + word.Length)) return false;
        Pos += word.Length;
        return true;
    }

    /// <summary>Plain digits, at most 18, standing alone.</summary>
    public bool Unsigned(out long value)
    {
        value = 0;
        int at = Pos;
        while (at < end && data[at] is >= (byte)'0' and <= (byte)'9')
        {
            if (at - Pos >= 18) return false;
            value = value * 10 + (data[at++] - '0');
        }
        if (at == Pos || !AtBoundary(at)) return false;
        Pos = at;
        return true;
    }

    /// <summary>The span of the value at Pos, after any white space; false when there is none or it is malformed.</summary>
    public bool Value(out Slice slice, int depth = 0, Dictionary<string, Slice>? keys = null)
    {
        SkipSpace();
        int start = Pos;
        bool ok = Value(depth, keys);
        slice = new Slice(start, Pos);
        return ok;
    }

    private bool Value(int depth, Dictionary<string, Slice>? keys)
    {
        if (depth > MaxDepth || Pos >= end) return false;
        switch (data[Pos])
        {
            case (byte)'/': return Name(out _);
            case (byte)'(': return LiteralString();
            case (byte)'<': return Pos + 1 < end && data[Pos + 1] == '<' ? ReadDictionary(depth, keys) : HexString();
            case (byte)'[': return ReadArray(depth);
            case (byte)'t': return Word("true"u8);
            case (byte)'f': return Word("false"u8);
            case (byte)'n': return Word("null"u8);
            default: return Number();
        }
    }

    public bool Name(out string name)
    {
        var text = new StringBuilder();
        name = "";
        int at = Pos + 1;
        while (at < end && !IsSpace(data[at]) && !IsDelimiter(data[at]))
        {
            byte b = data[at];
            if (b == '#')
            {
                if (at + 2 >= end || Hex(data[at + 1]) is not (>= 0 and var high) || Hex(data[at + 2]) is not (>= 0 and var low) || (high | low) == 0) return false;
                text.Append((char)(high << 4 | low));
                at += 3;
            }
            else if (b is < 0x21 or > 0x7E)
            {
                return false;
            }
            else
            {
                text.Append((char)b);
                at++;
            }
        }
        Pos = at;
        name = text.ToString();
        return true;
    }

    private static int Hex(byte c) => c switch
    {
        >= (byte)'0' and <= (byte)'9' => c - '0',
        >= (byte)'a' and <= (byte)'f' => c - 'a' + 10,
        >= (byte)'A' and <= (byte)'F' => c - 'A' + 10,
        _ => -1,
    };

    // A sign, digits and one point (7.3.3); "N G R" is a reference when both numbers are plain and in range.
    private bool Number()
    {
        int at = Pos;
        bool signed = data[at] is (byte)'+' or (byte)'-';
        if (signed) at++;
        int digits = 0, points = 0;
        for (; at < end && (data[at] is >= (byte)'0' and <= (byte)'9' || data[at] == '.'); at++)
        {
            if (data[at] == '.') points++;
            else digits++;
        }
        if (digits == 0 || points > 1 || !AtBoundary(at)) return false;
        if (signed || points > 0 || digits > 7)
        {
            Pos = at;
            return true;
        }
        Unsigned(out long number);
        int back = Pos;
        if (Pos < end && IsSpace(data[Pos]))
        {
            SkipSpace();
            if (Unsigned(out long generation) && Pos < end && IsSpace(data[Pos]))
            {
                SkipSpace();
                if (Word("R"u8)) return number is >= 1 and <= MaxNumber && generation <= 65535;
            }
        }
        Pos = back;
        return true;
    }

    private bool LiteralString()
    {
        int depth = 0;
        for (int at = Pos; at < end; at++)
        {
            byte b = data[at];
            if (b == '\\')
            {
                if (++at >= end) return false;
                byte next = data[at];
                if (next is >= (byte)'0' and <= (byte)'7')
                {
                    for (int n = 1; n < 3 && at + 1 < end && data[at + 1] is >= (byte)'0' and <= (byte)'7'; n++) at++;
                }
                else if (next == '\r')
                {
                    if (at + 1 < end && data[at + 1] == '\n') at++;
                }
                else if (Lengths is null && next is not ((byte)'n' or (byte)'r' or (byte)'t' or (byte)'b' or (byte)'f' or (byte)'(' or (byte)')' or (byte)'\\' or (byte)'\n'))
                {
                    return false;
                }
            }
            else if (b == '(')
            {
                depth++;
            }
            else if (b == ')' && --depth == 0)
            {
                Pos = at + 1;
                return true;
            }
        }
        return false;
    }

    private bool HexString()
    {
        for (int at = Pos + 1; at < end; at++)
        {
            if (data[at] == '>')
            {
                Pos = at + 1;
                return true;
            }
            if (!IsSpace(data[at]) && Hex(data[at]) < 0) return false;
        }
        return false;
    }

    private bool ReadArray(int depth)
    {
        Pos++;
        while (true)
        {
            SkipSpace();
            if (Pos < end && data[Pos] == ']')
            {
                Pos++;
                return true;
            }
            if (!Value(depth + 1, null)) return false;
        }
    }

    private bool ReadDictionary(int depth, Dictionary<string, Slice>? keys)
    {
        Pos += 2;
        var names = new HashSet<string>();
        while (true)
        {
            SkipSpace();
            if (Pos + 1 < end && data[Pos] == '>' && data[Pos + 1] == '>')
            {
                Pos += 2;
                return true;
            }
            if (Pos >= end || data[Pos] != '/' || !Name(out string key) || !names.Add(key)) return false;
            SkipSpace();
            int start = Pos;
            if (!Value(depth + 1, null)) return false;
            if (keys is not null) keys[key] = new Slice(start, Pos);
        }
    }

    /// <summary>"N G obj", the object, and "endobj" (7.3.10). A stream's data is exactly /Length bytes, a direct integer (7.3.8.2).</summary>
    public Indirect? Object()
    {
        SkipSpace();
        int start = Pos;
        if (!Unsigned(out long number) || number is < 1 or > MaxNumber) return null;
        SkipSpace();
        if (!Unsigned(out long generation) || generation > 65535) return null;
        SkipSpace();
        if (!Word("obj"u8)) return null;
        SkipSpace();
        var keys = Pos < end && data[Pos] == '<' && Pos + 1 < end && data[Pos + 1] == '<' ? new Dictionary<string, Slice>() : null;
        if (!Value(out _, 0, keys)) return null;
        SkipSpace();
        bool stream = keys is not null && Word("stream"u8);
        if (stream && !StreamData(keys!)) return null;
        SkipSpace();
        if (!Word("endobj"u8)) return null;
        return new Indirect((int)number, (int)generation, start, Pos, keys, stream);
    }

    private bool StreamData(Dictionary<string, Slice> keys)
    {
        if (Pos < end && data[Pos] == '\r' && Pos + 1 < end && data[Pos + 1] == '\n') Pos += 2;
        else if (Pos < end && data[Pos] == '\n') Pos++;
        else return false;
        if (!keys.TryGetValue("Length", out var slice) || !LengthOf(slice, out long length) || length > end - Pos) return false;
        Pos += (int)length;
        if (Pos < end && data[Pos] == '\r')
        {
            Pos++;
            if (Pos < end && data[Pos] == '\n') Pos++;
        }
        else if (Pos < end && data[Pos] == '\n')
        {
            Pos++;
        }
        return Word("endstream"u8);
    }

    private bool LengthOf(Slice slice, out long length)
    {
        if (Integer(slice, out length)) return true;
        return Lengths is not null && Reference(slice, out int number) && Lengths(number) is { } found && (length = found) >= 0;
    }

    /// <summary>The span holds nothing but a reference.</summary>
    public bool Reference(Slice slice, out int number)
    {
        number = 0;
        var reader = new StrictReader(data, slice.End) { Pos = slice.Start };
        if (!reader.Unsigned(out long n)) return false;
        reader.SkipSpace();
        if (!reader.Unsigned(out long generation)) return false;
        reader.SkipSpace();
        if (!reader.Word("R"u8) || reader.Pos != slice.End || n is < 1 or > MaxNumber || generation > 65535) return false;
        number = (int)n;
        return true;
    }

    /// <summary>The span holds nothing but a plain unsigned integer.</summary>
    public bool Integer(Slice slice, out long value)
    {
        var reader = new StrictReader(data, slice.End) { Pos = slice.Start };
        return reader.Unsigned(out value) && reader.Pos == slice.End;
    }

    /// <summary>The span holds nothing but a name.</summary>
    public bool NameOf(Slice slice, out string name)
    {
        var reader = new StrictReader(data, slice.End) { Pos = slice.Start };
        name = "";
        return slice.Start < slice.End && data[slice.Start] == '/' && reader.Name(out name) && reader.Pos == slice.End;
    }

    /// <summary>The span holds nothing but an array of plain unsigned integers.</summary>
    public bool Integers(Slice slice, out List<long> values)
    {
        values = [];
        var reader = new StrictReader(data, slice.End) { Pos = slice.Start };
        if (slice.Start >= slice.End || data[slice.Start] != '[') return false;
        reader.Pos++;
        while (true)
        {
            reader.SkipSpace();
            if (reader.Pos < slice.End && data[reader.Pos] == ']') return reader.Pos + 1 == slice.End;
            if (!reader.Unsigned(out long value)) return false;
            values.Add(value);
        }
    }

    /// <summary>The span holds nothing but an array of two values.</summary>
    public bool Pair(Slice slice, out Slice first, out Slice second)
    {
        first = second = default;
        var reader = new StrictReader(data, slice.End) { Pos = slice.Start };
        if (slice.Start >= slice.End || data[slice.Start] != '[') return false;
        reader.Pos++;
        if (!reader.Value(out first) || !reader.Value(out second)) return false;
        reader.SkipSpace();
        return reader.Pos + 1 == slice.End && data[reader.Pos] == ']';
    }

    public bool Same(Slice a, Slice b) => data.AsSpan(a.Start, a.End - a.Start).SequenceEqual(data.AsSpan(b.Start, b.End - b.Start));
}
