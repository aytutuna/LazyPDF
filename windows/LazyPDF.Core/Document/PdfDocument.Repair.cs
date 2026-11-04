namespace LazyPDF.Core;

// Repair: when the cross-reference data fails, the file is scanned once for "n g obj" and for
// trailers, and the table built from what is there, the newest definition of an object winning.
// One pass over the bytes; a stream is skipped by its length or its "endstream", so nothing is
// looked at twice.
public sealed partial class PdfDocument
{
    /// <summary>What a scan of the whole file found.</summary>
    private sealed class Scan
    {
        public Dictionary<int, (long Offset, int Generation)> Objects { get; } = [];
        public List<PdfDictionary> Trailers { get; } = [];
        public List<int> ObjectStreams { get; } = [];
        public List<int> Catalogs { get; } = [];
        public List<int> PageTrees { get; } = [];
        public List<int> Pages { get; } = [];
        public int Highest { get; set; }
        public long Wasted { get; set; }
    }

    private Scan? _scan;

    /// <summary>The table was rebuilt from a scan, so the offsets in the file's own cross-reference data cannot be built on.</summary>
    internal bool XrefRebuilt { get; private set; }

    private Scan EnsureScan() => _scan ??= RunScan();

    private Scan RunScan()
    {
        var scan = new Scan();
        int length = _data.Length;
        int pos = 0, nextObject = -1, nextTrailer = -1;
        while (true)
        {
            if (nextObject < pos) nextObject = Next("obj"u8, pos);
            if (nextTrailer < pos) nextTrailer = Next("trailer"u8, pos);
            if (nextObject == int.MaxValue && nextTrailer == int.MaxValue) break;
            if (nextTrailer < nextObject)
            {
                pos = nextTrailer + "trailer".Length;
                if (TryRead(scan, pos, nextTrailer, out var trailer, out int end))
                {
                    if (trailer is PdfDictionary dictionary) scan.Trailers.Add(dictionary);
                    pos = end;
                }
                continue;
            }
            int at = nextObject;
            pos = at + 3;
            if (!TryObjectHeader(at, out int start, out int number, out int generation)) continue;
            scan.Objects[number] = (start, generation);
            scan.Highest = Math.Max(scan.Highest, number);
            if (!TryRead(scan, pos, at, out var value, out int valueEnd)) continue;
            pos = Math.Max(pos, valueEnd);
            if (value is PdfStream stream)
            {
                stream.Number = number;
                pos = Math.Max(pos, ScanStreamEnd(stream));
            }
            Classify(scan, number, value is PdfStream s ? s.Dictionary : value as PdfDictionary);
        }
        return scan;
    }

    private int Next(ReadOnlySpan<byte> pattern, int from)
    {
        int at = _data.AsSpan(from).IndexOf(pattern);
        return at < 0 ? int.MaxValue : from + at;
    }

    /// <summary>
    /// Reads an object at <paramref name="position"/>. What a failed read cost is added up, and
    /// once it passes the file's size nothing more is parsed: a stray "(" that swallows the rest
    /// of the file would otherwise be paid for again at every later header.
    /// </summary>
    private bool TryRead(Scan scan, int position, int origin, out PdfObject? value, out int end)
    {
        value = null;
        end = position;
        if (scan.Wasted > _data.Length) return false;
        var lexer = new PdfLexer(_bytes, position);
        try
        {
            value = lexer.ReadObject();
            end = (int)lexer.Position;
            return true;
        }
        catch (PdfReadException)
        {
            scan.Wasted += lexer.Position - origin;
            return false;
        }
    }

    /// <summary>"n g obj" ending at the "obj" at <paramref name="at"/>; the digits before it are the number and generation.</summary>
    private bool TryObjectHeader(int at, out int start, out int number, out int generation)
    {
        start = number = generation = 0;
        if (at + 3 < _data.Length && IsRegular(_data[at + 3])) return false;
        int p = at - 1;
        if (!StepBackOver(ref p, white: true, 8)) return false;
        int generationEnd = p + 1;
        if (!StepBackOver(ref p, white: false, 6) || p + 1 == generationEnd) return false;
        int generationStart = p + 1;
        int gapEnd = p + 1;
        if (!StepBackOver(ref p, white: true, 8) || p + 1 == gapEnd) return false;
        int numberEnd = p + 1;
        if (!StepBackOver(ref p, white: false, 10) || p + 1 == numberEnd) return false;
        start = p + 1;
        long n = 0, g = 0;
        for (int i = start; i < numberEnd; i++) n = n * 10 + (_data[i] - '0');
        for (int i = generationStart; i < generationEnd; i++) g = g * 10 + (_data[i] - '0');
        if (n is < 1 or > MaxObjectNumber || g > 65535) return false;
        number = (int)n;
        generation = (int)g;
        return true;
    }

    /// <summary>Moves <paramref name="p"/> back over white space or digits, at most <paramref name="limit"/> of them; false when it ran into the limit.</summary>
    private bool StepBackOver(ref int p, bool white, int limit)
    {
        int steps = 0;
        while (p >= 0 && (white ? PdfLexer.IsWhiteSpace(_data[p]) : _data[p] is >= (byte)'0' and <= (byte)'9'))
        {
            if (++steps > limit) return false;
            p--;
        }
        return true;
    }

    private static bool IsRegular(byte b) => !PdfLexer.IsWhiteSpace(b) && !PdfLexer.IsDelimiter(b);

    private int ScanStreamEnd(PdfStream stream)
    {
        int start = (int)stream.DataOffset;
        long? declared = (stream.Dictionary["Length"] as PdfNumber)?.Integer;
        if (declared is >= 0 && declared <= _data.Length - start && EndstreamFollows(start + (int)declared)) return start + (int)declared;
        return FindStreamEnd(start);
    }

    private static void Classify(Scan scan, int number, PdfDictionary? dictionary)
    {
        switch ((dictionary?["Type"] as PdfName)?.Value)
        {
            case "ObjStm": scan.ObjectStreams.Add(number); break;
            case "XRef": scan.Trailers.Add(dictionary!); break;
            case "Catalog": scan.Catalogs.Add(number); break;
            case "Pages": scan.PageTrees.Add(number); break;
            case "Page": scan.Pages.Add(number); break;
        }
    }

    private void Rebuild(string reason)
    {
        AddRepair($"{reason} Rebuilt the cross-reference table by scanning the file.");
        var scan = EnsureScan();
        XrefRebuilt = true;
        StartXref = 0;
        XrefIsStream = false;
        _entries.Clear();
        _objects.Clear();
        _objectStreams.Clear();
        // Where each object was found: an object stream's members count as written where the stream is.
        var written = new Dictionary<int, long>(scan.Objects.Count);
        foreach (var (number, (offset, generation)) in scan.Objects)
        {
            _entries[number] = new Entry(EntryKind.InUse, offset, generation, 0);
            written[number] = offset;
        }

        var trailer = new PdfDictionary();
        long size = 0;
        foreach (var found in scan.Trailers)
        {
            foreach (string key in TrailerKeys)
            {
                if (found[key] is { } value) trailer[key] = value;
            }
            if (found["Size"] is PdfNumber { Integer: { } s }) size = Math.Max(size, s);
        }
        if (scan.Trailers.Count == 0) AddRepair("The file has no trailer.");
        Trailer = trailer;
        NextObjectNumber = (int)Math.Max(scan.Highest + 1, Math.Min(size, MaxObjectNumber));

        OpenSecurity();
        foreach (int streamNumber in scan.ObjectStreams)
        {
            if (LoadObjectStream(streamNumber) is not { } members) continue;
            long at = written[streamNumber];
            foreach (int number in members.Numbers)
            {
                if (written.TryGetValue(number, out long existing) && existing >= at) continue;
                _entries[number] = new Entry(EntryKind.Compressed, 0, 0, streamNumber);
                written[number] = at;
                NextObjectNumber = Math.Max(NextObjectNumber, number + 1);
            }
        }

        if (!CatalogUsable()) FindCatalog(scan);
        Trailer["Size"] = new PdfNumber(NextObjectNumber);
    }

    /// <summary>A catalog the trailer did not name, or failing that one made from the page tree that is there.</summary>
    private void FindCatalog(Scan scan)
    {
        var candidates = new List<int>(scan.Catalogs);
        // A catalog in an object stream is not in the scan: look at the stored ones if no plain one will do.
        if (!candidates.Any(HasPages)) candidates.AddRange(_entries.Where(e => e.Value.Kind == EntryKind.Compressed).Select(e => e.Key));
        for (int i = candidates.Count - 1; i >= 0; i--)
        {
            int number = candidates[i];
            if (Get(number) is PdfDictionary catalog && Name(catalog, "Type") == "Catalog" && HasPages(number))
            {
                Trailer["Root"] = new PdfReference(number, GenerationOf(number));
                Catalog = catalog;
                AddRepair($"Found the catalog (object {number}) by scanning.");
                return;
            }
        }

        PdfReference? tree = null;
        for (int i = scan.PageTrees.Count - 1; i >= 0 && tree is null; i--)
        {
            // The root of the tree is the node that has no parent.
            if (Get(scan.PageTrees[i]) is PdfDictionary node && Resolve(node["Parent"]) is null) tree = new PdfReference(scan.PageTrees[i], GenerationOf(scan.PageTrees[i]));
        }
        if (tree is null && scan.Pages.Count > 0)
        {
            var kids = new PdfArray([.. scan.Pages.Select(n => (PdfObject)new PdfReference(n, GenerationOf(n)))]);
            var root = new PdfDictionary();
            root.Add("Type", new PdfName("Pages"));
            root.Add("Kids", kids);
            root.Add("Count", new PdfNumber(scan.Pages.Count));
            tree = AddRepaired(root);
            AddRepair($"Made a page tree for {scan.Pages.Count} pages found by scanning.");
        }
        if (tree is null) throw PdfReadException.Damaged("The file has no catalog and no pages.");

        if (Resolve(Trailer["Root"]) is PdfDictionary existing)
        {
            existing["Pages"] = tree;
            Catalog = existing;
            AddRepair("The catalog had no page tree; set it to the one found.");
            return;
        }
        var made = new PdfDictionary();
        made.Add("Type", new PdfName("Catalog"));
        made.Add("Pages", tree);
        Trailer["Root"] = AddRepaired(made);
        Catalog = made;
        AddRepair("The file has no catalog; made one.");
    }

    private PdfReference AddRepaired(PdfObject value)
    {
        if (NextObjectNumber > MaxObjectNumber) throw PdfReadException.Damaged("The file has no object numbers left to repair it with.");
        return Add(value);
    }

    private bool HasPages(int number) => Get(number) is PdfDictionary catalog && Resolve(catalog["Pages"]) is PdfDictionary;
}
