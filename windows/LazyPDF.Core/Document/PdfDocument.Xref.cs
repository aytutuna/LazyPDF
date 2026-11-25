namespace LazyPDF.Core;

// Cross-reference sections as in Lazy Scan's PdfReaderLite.cs: classic tables, cross-reference
// streams (ISO 32000-1 7.5.8), /Prev chains and the /XRefStm of hybrid files (7.5.8.4).
public sealed partial class PdfDocument
{
    /// <summary>Longest /Prev chain followed (a loop is caught before that).</summary>
    internal const int MaxSections = 4096;

    internal enum EntryKind { Free, InUse, Compressed, New }

    /// <summary>One cross-reference entry: in use at an offset, in an object stream, free, or made since the file was read.</summary>
    internal readonly record struct Entry(EntryKind Kind, long Offset, int Generation, int StreamNumber);

    private static readonly string[] TrailerKeys = ["Root", "Info", "ID", "Encrypt"];
    private static readonly string[] XrefStreamKeys = ["Type", "W", "Index", "Length", "Filter", "DecodeParms", "Prev", "XRefStm"];

    private readonly Dictionary<int, Entry> _entries = [];
    private List<long> _sections = [];
    private readonly HashSet<long> _hybridStreams = [];
    private bool _loadingXref;

    /// <summary>Where the newest cross-reference section starts, as the file said; 0 when the table was rebuilt.</summary>
    internal long StartXref { get; private set; }

    /// <summary>The newest section is a cross-reference stream, so an update writes one too.</summary>
    internal bool XrefIsStream { get; private set; }

    /// <summary>The first object number not used: the trailer's /Size, or one past the highest listed when that is more.</summary>
    internal int NextObjectNumber { get; private set; }

    private void LoadCrossReferences()
    {
        long start = FindStartXref();
        var visited = new HashSet<long>();
        var sections = new List<long>();
        PdfDictionary? trailer = null;
        int highest = 0;
        long? offset = start;
        _loadingXref = true;
        try
        {
            while (offset is { } at)
            {
                if (!visited.Add(at)) throw PdfReadException.Damaged("The cross-reference sections point back at each other (/Prev).");
                if (visited.Count > MaxSections) throw PdfReadException.Damaged("Too many cross-reference sections.");
                sections.Add(at);
                var (dictionary, isStream, sectionHighest) = ReadSection(at);
                highest = Math.Max(highest, sectionHighest);
                if (trailer is null)
                {
                    XrefIsStream = isStream;
                    trailer = dictionary.Copy();
                }
                else
                {
                    foreach (string key in TrailerKeys)
                    {
                        if (!trailer.ContainsKey(key) && dictionary[key] is { } value) trailer[key] = value;
                    }
                }
                if (dictionary["Size"] is PdfNumber { Integer: { } size } && size - 1 <= MaxObjectNumber) highest = (int)Math.Max(highest, size - 1);
                offset = dictionary["Prev"] switch
                {
                    null => null,
                    PdfNumber { Value: > 0 } prev when prev.Value < _data.Length => (long)prev.Value,
                    _ => throw PdfReadException.Damaged("/Prev does not point into the file."),
                };
            }
        }
        finally
        {
            _loadingXref = false;
        }
        foreach (string key in XrefStreamKeys) trailer!.Remove(key);
        Trailer = trailer!;
        StartXref = start;
        _sections = sections;
        NextObjectNumber = highest + 1;
    }

    private long FindStartXref()
    {
        int at = _data.AsSpan().LastIndexOf("startxref"u8);
        if (at < 0) throw PdfReadException.Damaged("There is no startxref.");
        long? offset = new PdfLexer(_bytes, at + "startxref".Length).TryReadUnsigned();
        if (offset is null || offset <= 0 || offset >= _data.Length) throw PdfReadException.Damaged("startxref does not point into the file.");
        return offset.Value;
    }

    /// <summary>One section at <paramref name="offset"/>: its entries (newer ones already read win), its trailer dictionary.</summary>
    private (PdfDictionary Trailer, bool IsStream, int Highest) ReadSection(long offset)
    {
        var lexer = new PdfLexer(_bytes, offset);
        lexer.SkipWhiteSpace();
        long start = lexer.Position;
        if (lexer.ReadKeyword() == "xref")
        {
            var section = new Dictionary<int, Entry>();
            lexer.Position = ReadTable((int)lexer.Position, section, out int highest);
            if (lexer.ReadKeyword() != "trailer") throw PdfReadException.Damaged("A cross-reference table has no trailer.");
            if (lexer.ReadObject(allowStream: false) is not PdfDictionary trailer) throw PdfReadException.Damaged("The trailer is not a dictionary.");
            // A hybrid file: the classic table's objects, then the ones only its stream lists
            // (the table gives those as free, or not at all).
            if (trailer["XRefStm"] is { } streamOffset)
            {
                // Sections that name the same stream would decode it again for nothing: the newest named it first.
                if (streamOffset is not PdfNumber { Integer: { } so } || so <= 0 || so >= _data.Length) throw PdfReadException.Damaged("/XRefStm does not point into the file.");
                if (_hybridStreams.Add(so))
                {
                    var streamSection = new Dictionary<int, Entry>();
                    var (_, streamHighest) = ReadStreamSection(so, streamSection);
                    highest = Math.Max(highest, streamHighest);
                    foreach (var (number, entry) in streamSection)
                    {
                        if (!section.TryGetValue(number, out var listed) || listed.Kind == EntryKind.Free) section[number] = entry;
                    }
                }
            }
            Merge(section);
            return (trailer, false, highest);
        }
        var entries = new Dictionary<int, Entry>();
        var (dictionary, h) = ReadStreamSection(start, entries);
        Merge(entries);
        return (dictionary, true, h);
    }

    /// <summary>Entries of an older section count only where no newer one has spoken.</summary>
    private void Merge(Dictionary<int, Entry> section)
    {
        foreach (var (number, entry) in section) _entries.TryAdd(number, entry);
    }

    /// <summary>
    /// A classic table's subsections ("first count", then count lines of "offset generation n|f");
    /// the position after the last one. An offset past the file is kept: the object is looked for
    /// when it is wanted.
    /// </summary>
    private int ReadTable(int pos, Dictionary<int, Entry> section, out int highest)
    {
        highest = 0;
        while (true)
        {
            int save = pos;
            if (!ReadUnsigned(ref pos, out long first)) return save;
            if (!ReadUnsigned(ref pos, out long count)) throw PdfReadException.Damaged("A cross-reference subsection header is not two numbers.");
            if (first + count > MaxObjectNumber + 1L) throw PdfReadException.Damaged($"A cross-reference subsection goes past PDF's highest object number ({MaxObjectNumber}).");
            for (long i = 0; i < count; i++)
            {
                if (!ReadUnsigned(ref pos, out long entryOffset) || !ReadUnsigned(ref pos, out long generation))
                {
                    throw PdfReadException.Damaged($"Cross-reference entry {first + i} is not \"offset generation n|f\".");
                }
                while (pos < _data.Length && PdfLexer.IsWhiteSpace(_data[pos])) pos++;
                byte kind = pos < _data.Length ? _data[pos++] : (byte)0;
                if (kind is not ((byte)'n' or (byte)'f') || generation > 65535)
                {
                    throw PdfReadException.Damaged($"Cross-reference entry {first + i} is not \"offset generation n|f\".");
                }
                // A table that starts at 1 but opens with the free-list head was meant to start at 0.
                if (i == 0 && first == 1 && kind == 'f' && generation == 65535) first = 0;
                int number = (int)(first + i);
                if (number == 0) continue;
                bool inUse = kind == 'n' && entryOffset > 0;
                section.TryAdd(number, inUse
                    ? new Entry(EntryKind.InUse, entryOffset, (int)generation, 0)
                    : new Entry(EntryKind.Free, 0, (int)generation, 0));
                if (inUse) highest = Math.Max(highest, number);
            }
        }
    }

    /// <summary>Digits after white space; false (and <paramref name="pos"/> unchanged) when there are none or too many.</summary>
    private bool ReadUnsigned(ref int pos, out long value)
    {
        value = 0;
        int p = pos;
        while (p < _data.Length && PdfLexer.IsWhiteSpace(_data[p])) p++;
        int digits = 0;
        while (p < _data.Length && _data[p] is >= (byte)'0' and <= (byte)'9')
        {
            if (++digits > 18) return false;
            value = value * 10 + (_data[p++] - '0');
        }
        if (digits == 0) return false;
        pos = p;
        return true;
    }

    /// <summary>A cross-reference stream (/Type /XRef) at <paramref name="offset"/>: its entries and its dictionary.</summary>
    private (PdfDictionary Dictionary, int Highest) ReadStreamSection(long offset, Dictionary<int, Entry> section)
    {
        var lexer = new PdfLexer(_bytes, offset);
        var (number, generation) = lexer.ReadObjectHeader();
        if (lexer.ReadObject() is not PdfStream stream || stream.Dictionary["Type"] is not PdfName { Value: "XRef" })
        {
            throw PdfReadException.Damaged("startxref points at neither a cross-reference table nor a cross-reference stream.");
        }
        stream.Number = number;
        stream.Generation = generation;
        var dictionary = stream.Dictionary;
        // A cross-reference stream's own entries are direct: nothing can be looked up yet.
        if (dictionary["W"] is not PdfArray { Items.Count: 3 } w || w.Items.Any(i => i is not PdfNumber { Integer: >= 0 and <= 8 }))
        {
            throw PdfReadException.Damaged("A cross-reference stream's /W is not three field widths.");
        }
        int[] widths = [.. w.Items.Select(i => (int)((PdfNumber)i).Integer!.Value)];
        if (dictionary["Size"] is not PdfNumber { Integer: { } size } || size < 0) throw PdfReadException.Damaged("A cross-reference stream has no /Size.");
        var index = dictionary["Index"] is PdfArray indexArray
            ? indexArray.Items.Select(i => i is PdfNumber { Integer: { } n } && n is >= 0 and <= MaxObjectNumber + 1L ? n : throw PdfReadException.Damaged("A cross-reference stream's /Index is not numbers.")).ToList()
            : new List<long> { 0, size };
        if (index.Count % 2 != 0) throw PdfReadException.Damaged("A cross-reference stream's /Index has an odd count.");
        byte[] data = Data(stream);
        int entryLength = widths.Sum();
        if (entryLength == 0) throw PdfReadException.Damaged("A cross-reference stream's entries are empty.");
        int highest = 0;
        int at = 0;
        for (int k = 0; k < index.Count; k += 2)
        {
            long first = index[k], count = index[k + 1];
            if (first + count > MaxObjectNumber + 1L) throw PdfReadException.Damaged($"A cross-reference stream's /Index goes past PDF's highest object number ({MaxObjectNumber}).");
            for (long i = 0; i < count; i++)
            {
                if (at + entryLength > data.Length) throw PdfReadException.Damaged("A cross-reference stream is shorter than its /Index says.");
                // A missing first field means type 1.
                long type = widths[0] == 0 ? 1 : Field(data, at, widths[0]);
                long second = Field(data, at + widths[0], widths[1]);
                long third = Field(data, at + widths[0] + widths[1], widths[2]);
                at += entryLength;
                int objectNumber = (int)(first + i);
                if (objectNumber == 0) continue;
                Entry entry;
                switch (type)
                {
                    case 0:
                        entry = new Entry(EntryKind.Free, 0, (int)Math.Min(third, 65535), 0);
                        break;
                    case 1 when second > 0:
                        entry = new Entry(EntryKind.InUse, second, (int)Math.Min(third, 65535), 0);
                        highest = Math.Max(highest, objectNumber);
                        break;
                    case 2 when second is > 0 and <= int.MaxValue:
                        entry = new Entry(EntryKind.Compressed, 0, 0, (int)second);
                        highest = Math.Max(highest, objectNumber);
                        break;
                    default:
                        // Types a later PDF version may add read as null (7.5.8.3), and so hide the entry of an older section.
                        entry = new Entry(EntryKind.Free, 0, 0, 0);
                        break;
                }
                section.TryAdd(objectNumber, entry);
            }
        }
        return (dictionary, highest);
    }

    private static long Field(byte[] data, int at, int width)
    {
        long value = 0;
        for (int i = 0; i < width; i++) value = (value << 8) | data[at + i];
        return value;
    }
}
