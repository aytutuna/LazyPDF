using System.Text;

namespace LazyPDF.Core;

// The object table: loaded on first use and cached, as in Lazy Scan's PdfReaderLite.cs, with the
// objects of the file remembered as read so that a save can tell which ones changed.
public sealed partial class PdfDocument
{
    private const int MaxReferenceHops = 32;
    private const int MaxCachedObjectStreams = 256;
    private const long MaxCachedObjectStreamBytes = 128L << 20;
    private const int MaxObjectStreamSize = 64 << 20;
    // Reading an object can need another (a stream's /Length, an object stream); a longer chain is a trap.
    private const int MaxLoadDepth = 32;
    private const int MaxFlattenedNodes = 4096;

    /// <summary>A loaded object, its generation, and the fingerprint of its text when it was read.</summary>
    private sealed class Slot(PdfObject value, int generation, ulong print, bool isNew)
    {
        public PdfObject Value { get; set; } = value;
        public int Generation { get; } = generation;
        public ulong Print { get; } = print;
        public bool IsNew { get; } = isNew;
    }

    private sealed class ObjectStream(PdfArrayBytes bytes, int size, Dictionary<int, int> offsets, List<int> numbers)
    {
        public PdfArrayBytes Bytes { get; } = bytes;
        public int Size { get; } = size;
        public Dictionary<int, int> Offsets { get; } = offsets;
        public List<int> Numbers { get; } = numbers;
        public Dictionary<int, int> NumberIndex => _numberIndex ??= BuildNumberIndex();
        private Dictionary<int, int>? _numberIndex;

        private Dictionary<int, int> BuildNumberIndex()
        {
            var index = new Dictionary<int, int>(Numbers.Count);
            for (int i = 0; i < Numbers.Count; i++) index.TryAdd(Numbers[i], i);
            return index;
        }
    }

    private readonly Dictionary<int, Slot> _objects = [];
    private readonly Dictionary<int, ObjectStream> _objectStreams = [];
    private readonly HashSet<int> _loading = [];
    private readonly HashSet<int> _deleted = [];
    private readonly StringBuilder _printBuffer = new();
    private ulong _trailerPrint;
    private int _firstNew = int.MaxValue;

    /// <summary>
    /// Object <paramref name="number"/> as the newest revision has it, strings decrypted; null when
    /// it is free, not listed or cannot be read. The same instance comes back every time.
    /// </summary>
    public PdfObject? Get(int number)
    {
        if (_objects.TryGetValue(number, out var slot)) return slot.Value;
        if (!_entries.TryGetValue(number, out var entry) || entry.Kind is EntryKind.Free or EntryKind.New) return null;
        if (_loading.Count >= MaxLoadDepth || !_loading.Add(number)) return null;
        try
        {
            PdfObject? value;
            int generation = entry.Generation;
            if (entry.Kind == EntryKind.InUse)
            {
                value = ReadPlain(number, entry, out generation);
                if (value is not null && _security is not null && number != _encryptNumber) DecryptStrings(value, number, generation);
            }
            else
            {
                value = ReadCompressed(number, entry);
            }
            // An object that cannot be read stays null, without being tried again.
            value ??= PdfNull.Instance;
            _objects[number] = new Slot(value, generation, Print(value), isNew: false);
            return value;
        }
        finally
        {
            _loading.Remove(number);
        }
    }

    /// <summary>
    /// What a value stands for: a reference followed to the object it names, however many hops
    /// (a loop gives up after 32). Null for null, for a free or missing object.
    /// </summary>
    public PdfObject? Resolve(PdfObject? value)
    {
        int hops = 0;
        while (value is PdfReference reference)
        {
            if (++hops > MaxReferenceHops) return null;
            value = Get(reference.Number);
        }
        return value is PdfNull ? null : value;
    }

    public T? Resolve<T>(PdfObject? value) where T : PdfObject => Resolve(value) as T;

    public PdfDictionary? Dict(PdfDictionary? dictionary, string key) => Resolve(dictionary?[key]) as PdfDictionary;
    public PdfArray? Array(PdfDictionary? dictionary, string key) => Resolve(dictionary?[key]) as PdfArray;
    public PdfStream? Stream(PdfDictionary? dictionary, string key) => Resolve(dictionary?[key]) as PdfStream;
    public string? Name(PdfDictionary? dictionary, string key) => (Resolve(dictionary?[key]) as PdfName)?.Value;
    public bool? Bool(PdfDictionary? dictionary, string key) => (Resolve(dictionary?[key]) as PdfBoolean)?.Value;
    public double? Number(PdfDictionary? dictionary, string key) => (Resolve(dictionary?[key]) as PdfNumber)?.Value;

    /// <summary>An integer; a real that is whole (90.0) counts too.</summary>
    public long? Integer(PdfDictionary? dictionary, string key) =>
        Resolve(dictionary?[key]) is PdfNumber number ? number.Integer ?? WholeNumber(number.Value) : null;

    private static long? WholeNumber(double value) =>
        double.IsFinite(value) && Math.Abs(value) < long.MaxValue && value == Math.Floor(value) ? (long)value : null;

    public PdfRect? Rect(PdfDictionary? dictionary, string key) => Rect(dictionary?[key]);

    /// <summary>A rectangle from an array of four numbers (corners in any order); null for anything else or one with no area.</summary>
    public PdfRect? Rect(PdfObject? value)
    {
        if (Resolve(value) is not PdfArray { Items.Count: >= 4 } array) return null;
        Span<double> n = stackalloc double[4];
        for (int i = 0; i < 4; i++)
        {
            if (Resolve(array.Items[i]) is not PdfNumber { Value: var v } || !double.IsFinite(v)) return null;
            n[i] = v;
        }
        var rect = new PdfRect(n[0], n[1], n[2], n[3]);
        return rect.IsEmpty ? null : rect;
    }

    /// <summary>The generation of object <paramref name="number"/>; 0 for one that is not listed.</summary>
    internal int GenerationOf(int number) =>
        _objects.TryGetValue(number, out var slot) ? slot.Generation : _entries.TryGetValue(number, out var e) ? e.Generation : 0;

    /// <summary>Every object number the document lists as in use, ascending.</summary>
    public IReadOnlyList<int> ObjectNumbers => [.. _entries.Where(e => e.Value.Kind != EntryKind.Free).Select(e => e.Key).Order()];

    /// <summary>Makes <paramref name="value"/> an indirect object under a new number and returns its reference.</summary>
    public PdfReference Add(PdfObject value)
    {
        if (NextObjectNumber > MaxObjectNumber) throw new InvalidOperationException("The file has no object numbers left.");
        int number = NextObjectNumber++;
        Set(number, value);
        return new PdfReference(number, 0);
    }

    /// <summary>Gives object <paramref name="number"/> a new value; it is written at the next save whatever it holds.</summary>
    public void Set(int number, PdfObject value)
    {
        if (number is < 1 or > MaxObjectNumber) throw new ArgumentOutOfRangeException(nameof(number));
        int generation = GenerationOf(number);
        if (value is PdfStream stream)
        {
            // File-backed data is read with the number it was stored under.
            stream.Data ??= RawData(stream);
            stream.Number = number;
            stream.Generation = generation;
        }
        _entries[number] = new Entry(EntryKind.New, 0, generation, 0);
        _objects[number] = new Slot(value, generation, 0, isNew: true);
        _deleted.Remove(number);
        if (number >= NextObjectNumber) NextObjectNumber = number + 1;
    }

    /// <summary>Frees object <paramref name="number"/>; references to it then read as null.</summary>
    public void Delete(int number)
    {
        if (!_entries.TryGetValue(number, out var entry) || entry.Kind == EntryKind.Free) return;
        _objects.Remove(number);
        if (number >= _firstNew && entry.Kind == EntryKind.New)
        {
            _entries.Remove(number);
            return;
        }
        _entries[number] = new Entry(EntryKind.Free, 0, Math.Min(entry.Generation + 1, 65535), 0);
        _deleted.Add(number);
    }

    /// <summary>
    /// The numbers of the objects that are new or differ from what was read, ascending; freed ones
    /// are not among them. A loaded object is compared with the fingerprint of its text taken when
    /// it was read, a stream by its dictionary and by whether its <see cref="PdfStream.Data"/> was set.
    /// </summary>
    internal IReadOnlyList<int> ChangedObjects()
    {
        var changed = new List<int>();
        foreach (var (number, slot) in _objects)
        {
            if (slot.IsNew || slot.Value is PdfStream { Data: not null } || Print(slot.Value) != slot.Print) changed.Add(number);
        }
        changed.Sort();
        return changed;
    }

    /// <summary>The numbers freed since the file was read, ascending.</summary>
    internal IReadOnlyList<int> DeletedObjects => [.. _deleted.Order()];

    /// <summary>The trailer holds something other than what was read.</summary>
    internal bool TrailerChanged => Print(Trailer) != _trailerPrint;

    private ulong Print(PdfObject value)
    {
        _printBuffer.Clear();
        (value is PdfStream stream ? stream.Dictionary : value).WriteTo(_printBuffer);
        ulong hash = 14695981039346656037;
        foreach (var chunk in _printBuffer.GetChunks())
        {
            foreach (char c in chunk.Span) hash = (hash ^ c) * 1099511628211;
        }
        return hash + (ulong)_printBuffer.Length;
    }

    private PdfObject? ReadPlain(int number, Entry entry, out int generation)
    {
        if (TryParseAt(entry.Offset, number, out var value, out generation)) return value;
        var scan = EnsureScan();
        if (scan.Objects.TryGetValue(number, out var found) && found.Offset != entry.Offset
            && TryParseAt(found.Offset, number, out value, out generation))
        {
            AddRepair($"Object {number} was listed at byte {entry.Offset}; found at byte {found.Offset}.");
            _entries[number] = entry with { Offset = found.Offset };
            return value;
        }
        AddRepair($"Object {number} could not be read.");
        return null;
    }

    /// <summary>The object at <paramref name="offset"/> if its header is for <paramref name="number"/> (any number when it is 0) and it parses.</summary>
    private bool TryParseAt(long offset, int number, out PdfObject? value, out int generation)
    {
        value = null;
        generation = 0;
        if (offset < 0 || offset >= _data.Length) return false;
        try
        {
            var lexer = new PdfLexer(_bytes, offset);
            var (found, gen) = lexer.ReadObjectHeader();
            if (number != 0 && found != number) return false;
            value = lexer.ReadObject();
            generation = gen;
            if (value is PdfStream stream)
            {
                stream.Number = found;
                stream.Generation = gen;
            }
            return true;
        }
        catch (PdfReadException)
        {
            return false;
        }
    }

    private PdfObject? ReadCompressed(int number, Entry entry)
    {
        if (LoadObjectStream(entry.StreamNumber) is { } objects && objects.Offsets.TryGetValue(number, out int at))
        {
            try
            {
                return new PdfLexer(objects.Bytes, at).ReadObject(allowStream: false);
            }
            catch (PdfReadException)
            {
                AddRepair($"Object {number} in object stream {entry.StreamNumber} could not be read.");
                return null;
            }
        }
        AddRepair($"Object {number} is not in object stream {entry.StreamNumber}.");
        return null;
    }

    private ObjectStream? LoadObjectStream(int number)
    {
        if (_objectStreams.TryGetValue(number, out var cached)) return cached;
        if (Get(number) is not PdfStream stream || Name(stream.Dictionary, "Type") != "ObjStm") return null;
        long? n = Integer(stream.Dictionary, "N"), first = Integer(stream.Dictionary, "First");
        if (n is not >= 0 || first is not >= 0) return null;
        byte[] data;
        try
        {
            data = Data(stream, MaxObjectStreamSize);
        }
        catch (PdfReadException e)
        {
            AddRepair($"Object stream {number} could not be read ({e.Message}).");
            return null;
        }
        var bytes = new PdfArrayBytes(data);
        var header = new PdfLexer(bytes);
        var offsets = new Dictionary<int, int>();
        var numbers = new List<int>();
        for (long i = 0; i < n; i++)
        {
            long? objectNumber = header.TryReadUnsigned();
            long? relative = objectNumber is null ? null : header.TryReadUnsigned();
            if (objectNumber is null || relative is null)
            {
                AddRepair($"Object stream {number}'s header lists {i} objects, not the {n} it says.");
                break;
            }
            if (objectNumber is < 1 or > MaxObjectNumber || first + relative >= data.Length) continue;
            offsets.TryAdd((int)objectNumber.Value, (int)(first.Value + relative.Value));
            numbers.Add((int)objectNumber.Value);
        }
        if (_objectStreams.Count >= MaxCachedObjectStreams || _objectStreams.Values.Sum(o => (long)o.Size) + data.Length > MaxCachedObjectStreamBytes)
            _objectStreams.Clear();
        return _objectStreams[number] = new ObjectStream(bytes, data.Length, offsets, numbers);
    }

    /// <summary>
    /// Resolves the references in a value down to <paramref name="depth"/> levels, as the filters and
    /// the security handler want their parameters. Streams are left as they are, or read as nothing when
    /// <paramref name="streams"/> is false (a value that is written back as a direct one). Shared references
    /// would multiply at every level, so after a few thousand values the rest reads as nothing.
    /// </summary>
    private PdfObject? Flatten(PdfObject? value, int depth, bool streams = true)
    {
        int budget = MaxFlattenedNodes;
        return Flatten(value, depth, streams, ref budget);
    }

    private PdfObject? Flatten(PdfObject? value, int depth, bool streams, ref int budget)
    {
        switch (Resolve(value))
        {
            case PdfArray array when depth > 0:
                var items = new List<PdfObject>();
                foreach (var item in array.Items)
                {
                    if (--budget < 0) break;
                    items.Add(Flatten(item, depth - 1, streams, ref budget) ?? PdfNull.Instance);
                }
                return new PdfArray(items);
            case PdfDictionary dictionary when depth > 0:
                var copy = new PdfDictionary();
                foreach (var (key, item) in dictionary.Entries)
                {
                    if (--budget < 0) break;
                    copy.Add(key, Flatten(item, depth - 1, streams, ref budget) ?? PdfNull.Instance);
                }
                return copy;
            case PdfStream when !streams:
                return null;
            case var other:
                return other;
        }
    }
}
