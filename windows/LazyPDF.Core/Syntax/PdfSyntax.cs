using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

// From Lazy Scan's PdfSyntax.cs, opened up for a whole document: the values (ISO 32000-1 7.3), now
// editable. Strings and names keep their bytes, numbers their text, so a dictionary written back
// says exactly what it said.

/// <summary>A PDF value: null, boolean, number, name, string, array, dictionary, reference or stream.</summary>
public abstract class PdfObject
{
    /// <summary>The value in PDF syntax, as the writer puts it into a file.</summary>
    public abstract void WriteTo(StringBuilder output);

    public override string ToString()
    {
        var sb = new StringBuilder();
        WriteTo(sb);
        return sb.ToString();
    }
}

public sealed class PdfNull : PdfObject
{
    public static readonly PdfNull Instance = new();
    private PdfNull() { }
    public override void WriteTo(StringBuilder output) => output.Append("null");
}

public sealed class PdfBoolean(bool value) : PdfObject
{
    public bool Value { get; } = value;
    public override void WriteTo(StringBuilder output) => output.Append(Value ? "true" : "false");
}

/// <summary>An integer or a real, kept as it was written ("-.5", "4.", "0012").</summary>
public sealed class PdfNumber : PdfObject
{
    public PdfNumber(string text)
    {
        Text = text;
        Value = double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : 0;
        IsInteger = text.IndexOf('.') < 0;
    }

    public PdfNumber(long value) : this(value.ToString(CultureInfo.InvariantCulture)) { }

    /// <summary>A real, written with at most six decimals and no exponent.</summary>
    public PdfNumber(double value) : this(Format(value)) { }

    private static string Format(double value)
    {
        if (!double.IsFinite(value)) return "0";
        string text = Math.Round(value, 6).ToString("0.######", CultureInfo.InvariantCulture);
        return text == "-0" ? "0" : text;
    }

    public string Text { get; }
    public double Value { get; }
    public bool IsInteger { get; }

    /// <summary>The integer value; null for a real or one out of range.</summary>
    public long? Integer => IsInteger && long.TryParse(Text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long v) ? v : null;

    public override void WriteTo(StringBuilder output) => output.Append(Text);
}

/// <summary>A name: its bytes once #xx escapes are undone, one char per byte (Latin-1).</summary>
public sealed class PdfName(string value) : PdfObject
{
    public string Value { get; } = value;

    /// <summary>A name for free text: its UTF-8 bytes, one char each (7.3.5).</summary>
    public static PdfName FromText(string text) => new(Encoding.Latin1.GetString(Encoding.UTF8.GetBytes(text)));

    /// <summary>The text the bytes of <see cref="Value"/> spell as UTF-8, or Value itself when they are not UTF-8.</summary>
    public string Text
    {
        get
        {
            if (Value.Any(c => c > 0xFF)) return Value;
            try
            {
                return new UTF8Encoding(false, true).GetString(Encoding.Latin1.GetBytes(Value));
            }
            catch (ArgumentException)
            {
                return Value;
            }
        }
    }

    public override void WriteTo(StringBuilder output)
    {
        output.Append('/');
        // A char above 0xFF has no byte of its own, so its UTF-8 bytes go; then every non-ASCII char
        // goes that way, or the mix would not read back as UTF-8.
        bool wide = Value.Any(c => c > 0xFF);
        for (int i = 0; i < Value.Length; i++)
        {
            char c = Value[i];
            // Regular characters as they are; '#', delimiters, white space and anything outside
            // printable ASCII as #xx.
            if (c > 0x20 && c < 0x7F && c != '#' && !PdfLexer.IsDelimiter((byte)c)) output.Append(c);
            else if (c <= 0xFF && !(wide && c > 0x7F)) output.Append('#').Append(((int)c).ToString("X2", CultureInfo.InvariantCulture));
            else
            {
                int length = char.IsHighSurrogate(c) && i + 1 < Value.Length && char.IsLowSurrogate(Value[i + 1]) ? 2 : 1;
                foreach (byte b in Encoding.UTF8.GetBytes(Value.Substring(i, length))) output.Append('#').Append(b.ToString("X2", CultureInfo.InvariantCulture));
                i += length - 1;
            }
        }
    }

    public override bool Equals(object? obj) => obj is PdfName other && other.Value == Value;
    public override int GetHashCode() => Value.GetHashCode(StringComparison.Ordinal);
}

/// <summary>A string's bytes, and whether it was written in hex.</summary>
public sealed class PdfString(byte[] bytes, bool isHex) : PdfObject
{
    public byte[] Bytes { get; set; } = bytes;
    public bool IsHex { get; set; } = isHex;

    public override void WriteTo(StringBuilder output)
    {
        if (IsHex)
        {
            output.Append('<').Append(Convert.ToHexString(Bytes)).Append('>');
            return;
        }
        output.Append('(');
        foreach (byte b in Bytes)
        {
            switch (b)
            {
                case (byte)'\\': output.Append(@"\\"); break;
                case (byte)'(': output.Append(@"\("); break;
                case (byte)')': output.Append(@"\)"); break;
                // A bare CR in a literal string reads back as LF: escape it to keep the byte.
                case (byte)'\r': output.Append(@"\r"); break;
                case (byte)'\n': output.Append(@"\n"); break;
                default:
                    if (b < 0x20 || b >= 0x7F) output.Append('\\').Append(Convert.ToString(b, 8).PadLeft(3, '0'));
                    else output.Append((char)b);
                    break;
            }
        }
        output.Append(')');
    }
}

public sealed class PdfArray(List<PdfObject> items) : PdfObject
{
    public List<PdfObject> Items { get; } = items;

    public override void WriteTo(StringBuilder output)
    {
        output.Append('[');
        for (int i = 0; i < Items.Count; i++)
        {
            if (i > 0) output.Append(' ');
            Items[i].WriteTo(output);
        }
        output.Append(']');
    }
}

/// <summary>A dictionary, its entries in the order they were written (a repeated key: the last one counts).</summary>
public sealed class PdfDictionary : PdfObject
{
    // Past this many entries a lookup goes through an index instead of a scan.
    private const int IndexFrom = 12;

    private readonly List<KeyValuePair<string, PdfObject>> _entries = [];
    private Dictionary<string, int>? _last;

    public IReadOnlyList<KeyValuePair<string, PdfObject>> Entries => _entries;

    public int Count => _entries.Count;

    public PdfObject? this[string key]
    {
        get
        {
            int index = LastIndexOf(key);
            return index >= 0 ? _entries[index].Value : null;
        }
        set
        {
            if (value is null)
            {
                Remove(key);
                return;
            }
            int index = LastIndexOf(key);
            if (index >= 0) _entries[index] = new(key, value);
            else Add(key, value);
        }
    }

    public bool ContainsKey(string key) => LastIndexOf(key) >= 0;

    public void Add(string key, PdfObject value)
    {
        _entries.Add(new(key, value));
        if (_last is not null) _last[key] = _entries.Count - 1;
    }

    /// <summary>Removes every entry with <paramref name="key"/>; false when there was none.</summary>
    public bool Remove(string key)
    {
        if (_entries.RemoveAll(e => e.Key == key) == 0) return false;
        _last = null;
        return true;
    }

    private int LastIndexOf(string key)
    {
        if (_entries.Count < IndexFrom)
        {
            for (int i = _entries.Count - 1; i >= 0; i--)
            {
                if (_entries[i].Key == key) return i;
            }
            return -1;
        }
        if (_last is null)
        {
            _last = new Dictionary<string, int>(_entries.Count);
            for (int i = 0; i < _entries.Count; i++) _last[_entries[i].Key] = i;
        }
        return _last.TryGetValue(key, out int found) ? found : -1;
    }

    /// <summary>A copy whose entries can be changed without changing this one (the values are shared).</summary>
    public PdfDictionary Copy()
    {
        var copy = new PdfDictionary();
        foreach (var entry in _entries) copy._entries.Add(entry);
        return copy;
    }

    public override void WriteTo(StringBuilder output)
    {
        output.Append("<<");
        bool first = true;
        for (int i = 0; i < _entries.Count; i++)
        {
            var (key, value) = _entries[i];
            // The last of repeated keys only, where it was written.
            if (LastIndexOf(key) != i) continue;
            if (!first) output.Append(' ');
            first = false;
            new PdfName(key).WriteTo(output);
            output.Append(' ');
            value.WriteTo(output);
        }
        output.Append(">>");
    }
}

/// <summary>An indirect reference, "12 0 R".</summary>
public sealed class PdfReference(int number, int generation) : PdfObject
{
    public int Number { get; } = number;
    public int Generation { get; } = generation;

    public override void WriteTo(StringBuilder output) =>
        output.Append(Number.ToString(CultureInfo.InvariantCulture)).Append(' ')
              .Append(Generation.ToString(CultureInfo.InvariantCulture)).Append(" R");

    public override bool Equals(object? obj) => obj is PdfReference other && other.Number == Number && other.Generation == Generation;
    public override int GetHashCode() => HashCode.Combine(Number, Generation);
}

/// <summary>
/// A stream: its dictionary, and its data either where it starts in the bytes it was read from or
/// in memory. The length may be an indirect object, so the document works the data out
/// (<c>PdfDocument.RawData</c>).
/// </summary>
public sealed class PdfStream(PdfDictionary dictionary, long dataOffset) : PdfObject
{
    public PdfStream(PdfDictionary dictionary, byte[] data) : this(dictionary, -1) => Data = data;

    public PdfDictionary Dictionary { get; } = dictionary;

    /// <summary>Where the data starts in the file read; -1 for a stream made in memory.</summary>
    public long DataOffset { get; } = dataOffset;

    /// <summary>
    /// The data as it is to be stored, filters applied, not encrypted. Null for a stream read from
    /// a file whose data is still there; setting it replaces the data and marks the stream changed.
    /// </summary>
    public byte[]? Data { get; set; }

    /// <summary>The object number and generation of the stream, set where it becomes an indirect object.</summary>
    public int Number { get; internal set; }
    public int Generation { get; internal set; }

    /// <summary>Streams are never written back (an update only adds new ones).</summary>
    public override void WriteTo(StringBuilder output) =>
        throw new InvalidOperationException("A stream is written only as an indirect object.");
}
