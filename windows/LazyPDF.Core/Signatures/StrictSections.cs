namespace LazyPDF.Core;

// The cross-reference parts of an update, read by StrictReader: a table with its trailer or a stream, "startxref"
// and "%%EOF" (ISO 32000-1 7.5.4 to 7.5.8), and the members of an object stream.
internal sealed partial class UpdateGate
{
    // Type 0 is free, 1 in use at Second with generation Third, 2 the member Third of object stream Second.
    private readonly record struct Listed(int Number, int Type, long Second, long Third);

    private sealed record Section(int Start, Dictionary<string, Slice> Trailer, List<Listed> Entries, List<StrictReader.Indirect> Objects, int StreamNumber);

    private static readonly string[] TrailerKeys = ["Size", "Prev", "Root", "Info", "Encrypt", "ID"];
    private static readonly string[] StreamKeys = ["Type", "W", "Index", "Filter", "DecodeParms", "Length"];

    // The objects of an update up to its cross-reference section, which is read whole, "%%EOF" included.
    private Section? ReadSection(StrictReader reader, bool update)
    {
        var objects = new List<StrictReader.Indirect>();
        while (true)
        {
            reader.SkipSpace();
            int at = reader.Pos;
            if (reader.Word("xref"u8)) return ReadTable(reader, at, objects);
            if (reader.Object() is not { } o) return null;
            objects.Add(o);
            if (o.IsStream && o.Keys!.TryGetValue("Type", out var type) && reader.NameOf(type, out string name) && name == "XRef") return ReadStream(reader, o, objects, update);
        }
    }

    private Section? ReadTable(StrictReader reader, int start, List<StrictReader.Indirect> objects)
    {
        var entries = new List<Listed>();
        reader.SkipSpace();
        while (!reader.Word("trailer"u8))
        {
            if (!reader.Unsigned(out long first)) return null;
            reader.SkipSpace();
            if (!reader.Unsigned(out long count) || first + count > PdfDocument.MaxObjectNumber + 1L || count * 20 > _data.Length - reader.Pos) return null;
            reader.SkipSpace();
            for (long i = 0; i < count; i++)
            {
                if (TableEntry(reader.Pos, first + i) is not { } entry) return null;
                reader.Pos += 20;
                if (entry.Number > 0) entries.Add(entry);
            }
            reader.SkipSpace();
        }
        var trailer = new Dictionary<string, Slice>();
        if (!reader.Value(out var slice, 0, trailer) || !_data.AsSpan(slice.Start).StartsWith("<<"u8)) return null;
        return Tail(reader, start, trailer, entries, objects, 0);
    }

    // Twenty bytes: ten digits, a space, five digits, a space, n or f, and a two-byte line end (7.5.4).
    private Listed? TableEntry(int at, long number)
    {
        if (at + 20 > _data.Length || _data[at + 10] != ' ' || _data[at + 16] != ' ' || !Digits(at, 10, out long offset) || !Digits(at + 11, 5, out long generation)) return null;
        bool lineEnd = (_data[at + 18], _data[at + 19]) is ((byte)' ', (byte)'\n') or ((byte)' ', (byte)'\r') or ((byte)'\r', (byte)'\n');
        if (!lineEnd || generation > 65535) return null;
        return _data[at + 17] switch
        {
            (byte)'n' when number > 0 && offset > 0 && offset < int.MaxValue => new Listed((int)number, 1, offset, generation),
            (byte)'f' => new Listed((int)number, 0, offset, generation),
            _ => null,
        };
    }

    private bool Digits(int at, int count, out long value)
    {
        value = 0;
        for (int i = 0; i < count; i++)
        {
            if (_data[at + i] is not (>= (byte)'0' and <= (byte)'9')) return false;
            value = value * 10 + (_data[at + i] - '0');
        }
        return true;
    }

    private Section? ReadStream(StrictReader reader, StrictReader.Indirect o, List<StrictReader.Indirect> objects, bool update)
    {
        var entries = new List<Listed>();
        if (update && !StreamEntries(reader, o, entries)) return null;
        return Tail(reader, o.Start, o.Keys!, entries, objects, o.Number);
    }

    // "startxref", the offset of this section and "%%EOF".
    private static Section? Tail(StrictReader reader, int start, Dictionary<string, Slice> trailer, List<Listed> entries, List<StrictReader.Indirect> objects, int streamNumber)
    {
        reader.SkipSpace();
        if (!reader.Word("startxref"u8)) return null;
        reader.SkipSpace();
        if (!reader.Unsigned(out long at) || at != start) return null;
        reader.SkipSpace();
        return reader.Word("%%EOF"u8) ? new Section(start, trailer, entries, objects, streamNumber) : null;
    }

    // The rows of a cross-reference stream: /W three widths up to 8 bytes, /Index pairs (else 0 to /Size), and nothing left over (7.5.8.2).
    private bool StreamEntries(StrictReader reader, StrictReader.Indirect o, List<Listed> entries)
    {
        var keys = o.Keys!;
        if (!keys.TryGetValue("Size", out var size) || !reader.Integer(size, out long count)
            || !keys.TryGetValue("W", out var w) || !reader.Integers(w, out var widths) || widths.Count != 3 || widths.Any(x => x > 8) || widths.Sum() == 0) return false;
        var ranges = new List<long> { 0, count };
        if (keys.TryGetValue("Index", out var index) && (!reader.Integers(index, out ranges) || ranges.Count % 2 != 0)) return false;
        long rows = 0;
        for (int k = 0; k < ranges.Count; k += 2)
        {
            if (ranges[k] + ranges[k + 1] > PdfDocument.MaxObjectNumber + 1L) return false;
            rows += ranges[k + 1];
        }
        long width = widths.Sum();
        if (Decoded(o.Start) is not { } data || data.Length != rows * width) return false;
        int at = 0;
        for (int k = 0; k < ranges.Count; k += 2)
        {
            for (long i = 0; i < ranges[k + 1]; i++, at += (int)width)
            {
                long type = widths[0] == 0 ? 1 : Field(data, at, (int)widths[0]);
                long second = Field(data, at + (int)widths[0], (int)widths[1]), third = Field(data, at + (int)(widths[0] + widths[1]), (int)widths[2]);
                long number = ranges[k] + i;
                if (number > PdfDocument.MaxObjectNumber || type is < 0 or > 2 || second < 0 || third < 0) return false;
                if (number == 0 && type != 0) return false;
                if (type == 1 && (second == 0 || second >= int.MaxValue)) return false;
                if (type == 2 && (second == 0 || second > PdfDocument.MaxObjectNumber)) return false;
                if (number > 0) entries.Add(new Listed((int)number, (int)type, second, third));
            }
        }
        return true;
    }

    private static long Field(byte[] data, int at, int width)
    {
        long value = 0;
        for (int i = 0; i < width; i++) value = value << 8 | data[at + i];
        return value;
    }

    // The stream at offset, decoded the way the document decodes it (decrypted, filters applied); null when it cannot be.
    private byte[]? Decoded(int offset)
    {
        try
        {
            var lexer = new PdfLexer(new PdfArrayBytes(_data), offset);
            var (number, generation) = lexer.ReadObjectHeader();
            if (lexer.ReadObject() is not PdfStream stream) return null;
            stream.Number = number;
            stream.Generation = generation;
            return _b.Data(stream);
        }
        catch (PdfReadException)
        {
            return null;
        }
    }

    // The members of an object stream's data: /N pairs of number and offset, then each member's bytes to the next one's
    // start, the first at /First and the last to the end, so that every byte belongs to one member (7.5.7).
    private static List<(int Number, int Start, int End)>? Members(byte[] data, long count, long first)
    {
        if (count < 0 || first < 0 || first > data.Length || count > first) return null;
        var header = new StrictReader(data, (int)first);
        var starts = new List<(int Number, long Offset)>();
        for (long k = 0; k < count; k++)
        {
            header.SkipSpace();
            if (!header.Unsigned(out long number) || number is < 1 or > PdfDocument.MaxObjectNumber) return null;
            header.SkipSpace();
            if (!header.Unsigned(out long offset) || first + offset >= data.Length) return null;
            starts.Add(((int)number, first + offset));
        }
        header.SkipSpace();
        if (header.Pos != first || starts.Count == 0 || starts[0].Offset != first || starts.Select(s => s.Number).Distinct().Count() != starts.Count) return null;
        var members = new List<(int Number, int Start, int End)>();
        for (int k = 0; k < starts.Count; k++)
        {
            int next = k + 1 < starts.Count ? (int)starts[k + 1].Offset : data.Length;
            if (next <= starts[k].Offset) return null;
            var reader = new StrictReader(data, next) { Pos = (int)starts[k].Offset };
            if (!reader.Value(out _)) return null;
            reader.SkipSpace();
            if (!reader.AtEnd) return null;
            members.Add((starts[k].Number, (int)starts[k].Offset, next));
        }
        return members;
    }
}
