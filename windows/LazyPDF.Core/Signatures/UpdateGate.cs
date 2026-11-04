using System.Runtime.InteropServices;

namespace LazyPDF.Core;

// Decides whether everything after the signed bytes is something the checker can account for. The bytes are read by
// StrictReader alone, update by update: objects, a cross-reference section that lists each of them once and points
// exactly at it, "startxref", "%%EOF". Anything else, and any trailer that moves the catalog, is not judged further;
// the caller treats the file as changed. The tolerant reader is used only for what the strict one has already passed.
internal sealed partial class UpdateGate
{
    private const int MaxSections = 256;

    private readonly PdfDocument _a;
    private readonly PdfDocument _b;
    private readonly byte[] _data;
    private readonly Dictionary<int, Listed> _final = [];
    private readonly HashSet<int> _touched = [];
    private readonly HashSet<int> _defined = [];
    private readonly HashSet<int> _plumbing = [];
    private readonly Dictionary<int, bool> _signedStreams = [];
    private int _info;

    private UpdateGate(PdfDocument signed, PdfDocument final, byte[] data)
    {
        _a = signed;
        _b = final;
        _data = data;
    }

    /// <summary>
    /// What the updates list: every number they list, and those they give an object to at some point, even one a later
    /// update frees. <paramref name="Plumbing"/> are the cross-reference streams and object streams they write.
    /// </summary>
    public sealed record Listing(HashSet<int> Touched, HashSet<int> Defined, HashSet<int> Plumbing);

    /// <summary>
    /// What the updates after <paramref name="signed"/> list, or null when they cannot all be placed exactly.
    /// <paramref name="signed"/> must be the first part of <paramref name="final"/>, cut at the end of the signed bytes.
    /// </summary>
    public static Listing? Check(PdfDocument signed, PdfDocument final)
    {
        if (!MemoryMarshal.TryGetArray(final.Source, out var bytes) || bytes.Array is not { } data || data.Length != final.Length) return null;
        if (signed.Length > data.Length || signed.XrefRebuilt || final.XrefRebuilt || !data.AsSpan(0, signed.Length).SequenceEqual(signed.Source.Span)) return null;
        var gate = new UpdateGate(signed, final, data);
        return gate.Run() ? new Listing(gate._touched, gate._defined, gate._plumbing) : null;
    }

    private bool Run()
    {
        if (ReadSignedTail() is not { } tail) return false;
        var reader = new StrictReader(_data, _data.Length) { Pos = _a.Length };
        Section? last = null;
        int end = _a.Length;
        long size = tail.Size;
        long previous = _a.StartXref;
        for (int count = 0; ; count++)
        {
            reader.SkipSpace();
            if (reader.AtEnd) break;
            if (count >= MaxSections || ReadSection(reader, update: true) is not { } section || !Verify(section, tail, previous, ref size)) return false;
            (last, end, previous) = (section, reader.Pos, section.Start);
        }
        // A single line end may follow the last "%%EOF" (7.5.5).
        var rest = _data.AsSpan(end);
        if (last is null || !(rest.IsEmpty || rest.SequenceEqual("\n"u8) || rest.SequenceEqual("\r"u8) || rest.SequenceEqual("\r\n"u8))) return false;
        return _b.StartXref == last.Start && Tables() && Replaced();
    }

    private sealed record SignedTail(Section Section, long Size);

    // The section the signed revision ends with, read from where its startxref says: it has to run to the end of the
    // signed bytes, or a comment or an open object there could hide what the update then writes.
    private SignedTail? ReadSignedTail()
    {
        long at = _a.StartXref;
        if (at <= 0 || at >= _a.Length) return null;
        var reader = new StrictReader(_data, _a.Length) { Pos = (int)at };
        if (ReadSection(reader, update: false) is not { } section || section.Start != at) return null;
        for (int i = reader.Pos; i < _a.Length; i++)
        {
            if (!StrictReader.IsSpace(_data[i])) return null;
        }
        if (!section.Trailer.TryGetValue("Root", out var root) || _data[root.Start] is < (byte)'0' or > (byte)'9' || _data[root.End - 1] != 'R') return null;
        return section.Trailer.TryGetValue("Size", out var size) && new StrictReader(_data, _data.Length).Integer(size, out long value) ? new SignedTail(section, value) : null;
    }

    private bool Verify(Section section, SignedTail signed, long previous, ref long size)
    {
        var reader = new StrictReader(_data, _data.Length);
        var trailer = section.Trailer;
        if (!trailer.TryGetValue("Prev", out var prev) || !reader.Integer(prev, out long at) || at != previous) return false;
        if (!trailer.TryGetValue("Size", out var sizeSlice) || !reader.Integer(sizeSlice, out long newSize)) return false;
        // The catalog and encryption are the signed revision's own, in the same bytes. Information may be added where there was
        // none, but as an object of this update, which the rules then judge: a direct dictionary or an old object touches nothing.
        foreach (string key in (string[])["Root", "Info", "Encrypt"])
        {
            bool before = signed.Section.Trailer.TryGetValue(key, out var was), after = trailer.TryGetValue(key, out var now);
            if (key == "Info" && !before && after)
            {
                if (!NewInfo(reader, now, section)) return false;
                continue;
            }
            if (before != after || before && !reader.Same(was, now)) return false;
        }
        if (!SameId(reader, signed.Section.Trailer, trailer) || !KeysKnown(reader, section, signed.Section.Trailer)) return false;

        var listed = new HashSet<int>();
        foreach (var entry in section.Entries)
        {
            if (!listed.Add(entry.Number)) return false;
        }
        // The size is the first number nothing in the file has (7.5.5).
        if (newSize != Math.Max(size, Math.Max(listed.Count == 0 ? 0 : listed.Max(), section.StreamNumber) + 1L)) return false;
        size = newSize;
        if (!ObjectsListed(section) || !MembersListed(section)) return false;
        if (section.StreamNumber > 0) _plumbing.Add(section.StreamNumber);
        foreach (var entry in section.Entries)
        {
            _final[entry.Number] = entry;
            _touched.Add(entry.Number);
            if (entry.Type != 0) _defined.Add(entry.Number);
        }
        return true;
    }

    // The keys of an update's trailer are the ones listed, and any other the signed revision's writer left there that the
    // update repeats as it was (our own writers do): a key that points at more cross-reference data never passes.
    private static bool KeysKnown(StrictReader reader, Section section, Dictionary<string, Slice> signed)
    {
        foreach (var (key, value) in section.Trailer)
        {
            if (TrailerKeys.Contains(key) || section.StreamNumber > 0 && StreamKeys.Contains(key)) continue;
            if (key == "XRefStm" || !signed.TryGetValue(key, out var was) || !reader.Same(was, value)) return false;
        }
        return true;
    }

    // A reference to an object this update gives, or the one an earlier update gave.
    private bool NewInfo(StrictReader reader, Slice info, Section section)
    {
        if (!reader.Reference(info, out int number)) return false;
        bool given = number == _info || section.Entries.Any(e => e.Number == number && e.Type != 0)
            && !(_a.Entries.TryGetValue(number, out var was) && was.Kind != PdfDocument.EntryKind.Free);
        if (given) _info = number;
        return given;
    }

    // An update changes the second string of /ID and keeps the first (14.4).
    private static bool SameId(StrictReader reader, Dictionary<string, Slice> before, Dictionary<string, Slice> after)
    {
        if (!before.TryGetValue("ID", out var was) || !after.TryGetValue("ID", out var now)) return !before.ContainsKey("ID") && !after.ContainsKey("ID");
        return reader.Pair(was, out var first, out _) && reader.Pair(now, out var next, out _) && reader.Same(first, next);
    }

    // Each entry in use leads to an "N G obj" of this update with the same number and generation, and each object is listed once.
    private static bool ObjectsListed(Section section)
    {
        var byStart = section.Objects.ToDictionary(o => o.Start);
        int matched = 0;
        foreach (var entry in section.Entries.Where(e => e.Type == 1))
        {
            if (!byStart.TryGetValue((int)entry.Second, out var o) || o.Number != entry.Number || o.Generation != entry.Third) return false;
            matched++;
        }
        return matched == section.Objects.Count;
    }

    // Every member of an object stream the update writes is listed as that member, and nothing else is listed as one.
    private bool MembersListed(Section section)
    {
        var expected = new HashSet<(int, long, long)>();
        var reader = new StrictReader(_data, _data.Length);
        foreach (var o in section.Objects)
        {
            if (!o.IsStream || !o.Keys!.TryGetValue("Type", out var type) || !reader.NameOf(type, out string name) || name != "ObjStm") continue;
            if (o.Keys.ContainsKey("Extends") || !o.Keys.TryGetValue("N", out var n) || !reader.Integer(n, out long count)
                || !o.Keys.TryGetValue("First", out var f) || !reader.Integer(f, out long first)) return false;
            if (Decoded(o.Start) is not { } data || Members(data, count, first) is not { } members) return false;
            for (int k = 0; k < members.Count; k++)
            {
                if (members[k].Number == o.Number) return false;
                expected.Add((members[k].Number, o.Number, k));
            }
            _plumbing.Add(o.Number);
        }
        var found = section.Entries.Where(e => e.Type == 2).Select(e => (e.Number, e.Second, e.Third)).ToList();
        return found.Count == expected.Count && found.All(expected.Contains);
    }

    // What the document made of the tables is what the strict read found: no entry moved, none repaired, the chain intact.
    private bool Tables()
    {
        foreach (var (number, entry) in _final)
        {
            _b.Entries.TryGetValue(number, out var now);
            bool same = entry.Type switch
            {
                0 => now.Kind == PdfDocument.EntryKind.Free,
                1 => now.Kind == PdfDocument.EntryKind.InUse && now.Offset == entry.Second && now.Generation == entry.Third,
                _ => now.Kind == PdfDocument.EntryKind.Compressed && now.StreamNumber == entry.Second,
            };
            if (!same) return false;
        }
        foreach (int number in _a.Entries.Keys.Concat(_b.Entries.Keys))
        {
            if (!_final.ContainsKey(number) && _a.Entries.GetValueOrDefault(number) != _b.Entries.GetValueOrDefault(number)) return false;
        }
        return true;
    }

    // The copy of an object the update replaces or frees must itself be exact: another reader may take its odd bytes
    // for something else, and the update then "changes" it into what this reader saw all along.
    private bool Replaced()
    {
        foreach (int number in _touched)
        {
            if (!_a.Entries.TryGetValue(number, out var entry)) continue;
            if (entry.Kind == PdfDocument.EntryKind.InUse)
            {
                if (entry.Offset >= _a.Length) return false;
                var reader = new StrictReader(_data, _a.Length) { Pos = (int)entry.Offset, Lengths = SignedLength };
                if (reader.Object() is not { } o || o.Number != number) return false;
            }
            else if (entry.Kind == PdfDocument.EntryKind.Compressed && !SignedStreamExact(entry.StreamNumber))
            {
                return false;
            }
        }
        return true;
    }

    private long? SignedLength(int number) => _a.Get(number) is PdfNumber { Value: var value } ? (long)value : null;

    private bool SignedStreamExact(int number)
    {
        if (_signedStreams.TryGetValue(number, out bool known)) return known;
        bool exact = false;
        try
        {
            if (_a.Get(number) is PdfStream stream && _a.Integer(stream.Dictionary, "N") is { } count && _a.Integer(stream.Dictionary, "First") is { } first)
            {
                exact = Members(_a.Data(stream), count, first) is not null;
            }
        }
        catch (PdfReadException)
        {
        }
        return _signedStreams[number] = exact;
    }
}
