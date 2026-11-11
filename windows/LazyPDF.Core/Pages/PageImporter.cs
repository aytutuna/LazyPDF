namespace LazyPDF.Core;

// Copies pages from one document into another. When both are the same document the copies share
// everything but their annotations and form fields. One importer is one import: its map from source
// objects to copies lives as long as it does, so a font or image used by many pages is copied once.
// References are followed through a work queue, not by recursion, so a chain of a million objects
// costs no stack and a cycle ends where it closes.
internal sealed partial class PageImporter
{
    private static readonly string[] PageOnly = ["Type", "Parent", "B", "StructParents", "Annots", "Resources", "MediaBox", "CropBox", "Rotate"];

    private readonly PdfDocument _source;
    private readonly PdfDocument _target;
    private readonly bool _same;
    private readonly HashSet<int> _sourcePages;
    private readonly Dictionary<int, PdfReference> _map = [];
    private readonly Dictionary<int, PdfReference> _newPages = [];
    private readonly Queue<(int Source, int Target)> _pending = [];

    /// <summary>Whether the pages and annotations keep their keys into the tag tree, which <see cref="CopyTree"/> then copies.</summary>
    public bool KeepTags { get; set; }

    public PageImporter(PdfDocument source, PdfDocument target)
    {
        _source = source;
        _target = target;
        _same = ReferenceEquals(source, target);
        _sourcePages = [.. source.Pages.Select(p => p.Reference.Number)];
    }

    /// <summary>Copies the pages at these source indexes (repeats give separate copies); the new pages belong to no tree yet.</summary>
    public List<PdfReference> Import(IReadOnlyList<int> indexes, CancellationToken cancel = default)
    {
        var pages = _source.Pages;
        // A field made by an earlier import is not this one's: the copies of a document listed twice each get their own.
        _fields.Clear();
        var made = new List<(PdfPage Page, PdfReference Ref, PdfDictionary Dict)>();
        foreach (int index in indexes)
        {
            cancel.ThrowIfCancellationRequested();
            if ((uint)index >= (uint)pages.Count) throw new ArgumentOutOfRangeException(nameof(indexes), $"There is no page {index + 1}.");
            var dict = new PdfDictionary();
            var reference = _target.Add(dict);
            // Links between pages that come across all go to the new pages; a repeated page is reached at its first copy.
            if (!_same) _newPages.TryAdd(pages[index].Reference.Number, reference);
            made.Add((pages[index], reference, dict));
        }
        var seen = new HashSet<int>();
        foreach (var (page, reference, dict) in made)
        {
            cancel.ThrowIfCancellationRequested();
            if (!seen.Add(page.Reference.Number)) _fields.Clear();
            FillPage(page, reference, dict);
        }
        TrimGroups();
        CarryOrder();
        Drain();
        MergeLayers();
        return [.. made.Select(m => m.Ref)];
    }

    /// <summary>A copy of a value from the source, its references copied with it.</summary>
    public PdfObject CopyValue(PdfObject value)
    {
        var copy = Copy(value);
        Drain();
        return copy;
    }

    /// <summary>A copy of the source's structure tree in which a page that did not come across is <paramref name="ghost"/>.</summary>
    public PdfObject CopyTree(PdfObject root, PdfReference ghost)
    {
        var mapped = _sourcePages.Where(n => _newPages.TryAdd(n, ghost)).ToList();
        foreach (var (number, annotation) in _taggedCopies) _map.TryAdd(number, annotation);
        var copy = CopyValue(root);
        foreach (int number in mapped) _newPages.Remove(number);
        return copy;
    }

    private void FillPage(PdfPage page, PdfReference reference, PdfDictionary dict)
    {
        dict["Type"] = new PdfName("Page");
        // Written out even when equal to the default, so that nothing is inherited from the new tree (7.7.3.4).
        dict["MediaBox"] = page.MediaBox.ToArray();
        dict["CropBox"] = page.CropBox.ToArray();
        dict["Rotate"] = new PdfNumber((long)page.Rotate);
        dict["Resources"] = Copy(Pruned(page, Inherited(page, "Resources") ?? page.Resources ?? new PdfDictionary()));
        foreach (var (key, value) in page.Dictionary.Entries)
        {
            if ((PageOnly.Contains(key) && !(KeepTags && key == "StructParents")) || !ReferenceEquals(page.Dictionary[key], value)) continue;
            var copy = Copy(value);
            if (copy is not PdfNull) dict.Add(key, copy);
        }
        CopyAnnotations(page, reference, dict);
    }

    private PdfObject? Inherited(PdfPage page, string key)
    {
        var node = page.Dictionary;
        for (int depth = 0; node is not null && depth < 64; depth++)
        {
            if (node[key] is { } value and not PdfNull) return value;
            node = _source.Dict(node, "Parent");
        }
        return null;
    }

    private PdfObject Copy(PdfObject value)
    {
        return value switch
        {
            PdfReference reference => _same ? reference : CopyReference(reference),
            PdfArray array => new PdfArray([.. array.Items.Select(Copy)]),
            PdfDictionary dictionary => CopyDictionary(dictionary),
            PdfString text => new PdfString([.. text.Bytes], text.IsHex),
            _ => value,
        };
    }

    private PdfDictionary CopyDictionary(PdfDictionary source)
    {
        var copy = new PdfDictionary();
        foreach (var (key, value) in source.Entries)
        {
            if (!ReferenceEquals(source[key], value)) continue;
            var item = Copy(value);
            if (item is not PdfNull) copy.Add(key, item);
        }
        return copy;
    }

    private PdfObject CopyReference(PdfReference reference)
    {
        if (_map.TryGetValue(reference.Number, out var done) || _newPages.TryGetValue(reference.Number, out done)) return done;
        // A page that did not come across, the tree above it and the catalog would drag the whole file in.
        var value = _source.Get(reference.Number);
        if (value is null or PdfNull || _sourcePages.Contains(reference.Number) || IsStructure(value)) return PdfNull.Instance;
        var made = _target.Add(PdfNull.Instance);
        _map[reference.Number] = made;
        _pending.Enqueue((reference.Number, made.Number));
        return made;
    }

    private bool IsStructure(PdfObject value) =>
        value is PdfDictionary dictionary && _source.Name(dictionary, "Type") is "Page" or "Pages" or "Catalog";

    private void Drain()
    {
        while (_pending.TryDequeue(out var item))
        {
            var value = _source.Get(item.Source)!;
            _target.Set(item.Target, value is PdfStream stream ? CopyStream(stream) : Copy(value));
        }
    }

    private PdfStream CopyStream(PdfStream stream)
    {
        // A form's own resources are pruned like a page's, so that a shared set does not carry the whole file along.
        bool form = !_same && _source.Name(stream.Dictionary, "Subtype") == "Form" && stream.Dictionary["Resources"] is { } own && _source.Resolve(own) is PdfDictionary;
        var shell = stream.Dictionary;
        if (form)
        {
            shell = stream.Dictionary.Copy();
            shell.Remove("Resources");
        }
        var dict = CopyDictionary(shell);
        if (form) dict["Resources"] = Copy(PrunedForm(stream, stream.Dictionary["Resources"]!));
        dict.Remove("Length");
        // The data comes out of the source decrypted; its Crypt stage has been carried out and does not go along.
        var (filter, parameters, crypt) = _source.DecodeSpec(stream);
        if (crypt)
        {
            dict.Remove("Filter");
            dict.Remove("DecodeParms");
            if (filter is not null) dict["Filter"] = Copy(filter);
            if (parameters is not (null or PdfNull)) dict["DecodeParms"] = Copy(parameters);
        }
        return new PdfStream(dict, _source.RawData(stream));
    }
}
