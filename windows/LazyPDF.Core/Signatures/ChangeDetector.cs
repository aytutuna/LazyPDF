namespace LazyPDF.Core;

// Compares the revision a signature closes with the file as it is, object by object, and says what changed
// and whether the signature's level allows it. Roles (catalog, form, field, page, annotation) are taken from the
// signed revision, so nothing a later revision declares can talk its own changes into being allowed.
internal sealed partial class ChangeDetector
{
    private const int MaxFields = 200_000;
    private const int MaxDepth = 32;

    private readonly PdfDocument _a;
    private readonly PdfDocument _b;
    private readonly int _level;
    private readonly IReadOnlyList<PdfDocument>? _between;
    private readonly List<SignatureChange> _changes = [];
    private readonly HashSet<int> _claimed = [];
    private readonly HashSet<int> _modified = [];

    private readonly int _catalog;
    private readonly int _info;
    private readonly int _metadata;
    private readonly int _acroForm;
    private readonly int _fieldsArray;
    private readonly Dictionary<int, int> _pages = [];
    private readonly Dictionary<int, int> _annots = [];
    private readonly Dictionary<int, int> _annotArrays = [];
    private readonly Dictionary<int, FieldNode> _fields = [];
    private readonly Dictionary<int, int> _widgetFields = [];
    private readonly List<(FieldLockAction Action, HashSet<string> Names)> _locks = [];
    private HashSet<int>? _content;
    private HashSet<int>? _reachable;
    private HashSet<int>? _dss;
    private Dictionary<int, int>? _appearanceOwner;

    private sealed record FieldNode(string Name, bool IsSignature, bool HasValue);

    private ChangeDetector(PdfDocument before, PdfDocument after, int level, IReadOnlyList<PdfDocument>? between)
    {
        _between = between;
        _a = before;
        _b = after;
        _level = level;
        _catalog = Number(before.Trailer["Root"]);
        _info = Number(before.Trailer["Info"]);
        _metadata = Number(before.Catalog["Metadata"]);
        _acroForm = Number(before.Catalog["AcroForm"]);
        if (before.Dict(before.Catalog, "AcroForm") is { } form) _fieldsArray = Number(form["Fields"]);
        for (int i = 0; i < before.Pages.Count; i++)
        {
            if (before.Pages[i].Reference is { } page) _pages[page.Number] = i;
            IndexAnnotations(before.Pages[i], i);
        }
        IndexFields();
    }

    /// <summary>
    /// The changes from <paramref name="before"/> to <paramref name="after"/> judged at <paramref name="level"/>:
    /// 0 for a file that is not certified, else the /DocMDP permission 1 to 3. <paramref name="between"/> are the
    /// revisions in between, which tell an object left over from an earlier update from one that was slipped in;
    /// null skips that check.
    /// </summary>
    public static SignatureChangeReport Compare(PdfDocument before, PdfDocument after, int level, IReadOnlyList<PdfDocument>? between)
    {
        var detector = new ChangeDetector(before, after, level, between);
        detector.Run();
        return new SignatureChangeReport(detector._changes, 0);
    }

    private static int Number(PdfObject? value) => value is PdfReference r ? r.Number : 0;

    private bool Permits(SignatureChangeKind kind) => kind switch
    {
        SignatureChangeKind.ValidationData => true,
        SignatureChangeKind.Signature => _level != 1,
        SignatureChangeKind.FormFill => _level >= 2,
        SignatureChangeKind.Comment => _level == 3,
        SignatureChangeKind.Metadata => _level >= 2,
        _ => false,
    };

    private void Report(SignatureChangeKind kind, int number, int page = -1, string? field = null, bool? allowed = null) =>
        _changes.Add(new SignatureChange(kind, number, page, field, allowed ?? Permits(kind)));

    private void Run()
    {
        if (_b.XrefRebuilt && !_a.XrefRebuilt) Report(SignatureChangeKind.Other, 0, allowed: false);
        if (Number(_a.Trailer["Root"]) != Number(_b.Trailer["Root"])) Report(SignatureChangeKind.PageStructure, Number(_b.Trailer["Root"]), allowed: false);
        if (Number(_a.Trailer["Info"]) != Number(_b.Trailer["Info"]) && _b.Trailer["Info"] is not null) Report(SignatureChangeKind.Metadata, Number(_b.Trailer["Info"]));
        if (_a.Trailer["Encrypt"]?.ToString() != _b.Trailer["Encrypt"]?.ToString()) Report(SignatureChangeKind.Other, 0, allowed: false);

        var numbers = new SortedSet<int>(_a.ObjectNumbers);
        numbers.UnionWith(_b.ObjectNumbers);
        var added = new List<int>();
        var removed = new List<int>();
        foreach (int n in numbers)
        {
            _a.Entries.TryGetValue(n, out var ea);
            _b.Entries.TryGetValue(n, out var eb);
            bool inA = ea.Kind is PdfDocument.EntryKind.InUse or PdfDocument.EntryKind.Compressed;
            bool inB = eb.Kind is PdfDocument.EntryKind.InUse or PdfDocument.EntryKind.Compressed;
            if (inA && inB && ea.Kind == PdfDocument.EntryKind.InUse && ea == eb) continue;
            if (!inA && !inB) continue;
            if (inA && inB)
            {
                var va = _a.Get(n);
                var vb = _b.Get(n);
                if (va is null || vb is null || Same(va, vb)) continue;
                _modified.Add(n);
                Modified(n, va, vb);
            }
            else if (inB)
            {
                added.Add(n);
            }
            else
            {
                removed.Add(n);
            }
        }
        var held = removed.Where(Held).ToHashSet();
        var stillUsed = new HashSet<int>();
        if (held.Count > 0)
        {
            foreach (int m in _b.ObjectNumbers)
            {
                if (_b.Get(m) is { } value) Collect(value, held, stillUsed, 0);
            }
        }
        foreach (int n in removed) Removed(n, stillUsed.Contains(n));
        Unclaimed(added);
        if (_between is not null) Orphans();
    }

    private bool Same(PdfObject a, PdfObject b)
    {
        if (a is PdfStream sa && b is PdfStream sb)
        {
            return sa.Dictionary.ToString() == sb.Dictionary.ToString() && _a.RawData(sa).AsSpan().SequenceEqual(_b.RawData(sb));
        }
        return a.GetType() == b.GetType() && a.ToString() == b.ToString();
    }

    private void IndexAnnotations(PdfPage page, int index)
    {
        if (page.Dictionary["Annots"] is PdfReference array) _annotArrays[array.Number] = index;
        if (_a.Array(page.Dictionary, "Annots") is not { } annots) return;
        foreach (var item in annots.Items)
        {
            if (item is PdfReference r) _annots[r.Number] = index;
        }
    }

    private void IndexFields()
    {
        if (_a.Dict(_a.Catalog, "AcroForm") is not { } form || _a.Array(form, "Fields") is not { } fields) return;
        foreach (var item in fields.Items)
        {
            if (item is PdfReference r) Walk(r, "", false, 0);
        }
        // A signed field's own lock and the locks its signatures declare.
        foreach (var (number, node) in _fields)
        {
            if (!node.IsSignature || !node.HasValue || _a.Get(number) is not PdfDictionary field) continue;
            if (_a.Dict(field, "V") is { } signature && _a.Array(signature, "Reference") is { } references) ReadLocks(references);
        }
    }

    private void Walk(PdfReference reference, string prefix, bool inheritedSignature, int depth)
    {
        if (depth > MaxDepth || _fields.Count > MaxFields || _fields.ContainsKey(reference.Number) || _a.Get(reference.Number) is not PdfDictionary dictionary) return;
        string name = prefix;
        if (PdfText.Read(_a, dictionary["T"]) is { } partial) name = name.Length == 0 ? partial : name + "." + partial;
        bool signature = _a.Name(dictionary, "FT") is { } type ? type == "Sig" : inheritedSignature;
        _fields[reference.Number] = new FieldNode(name, signature, dictionary["V"] is not null && dictionary["V"] is not PdfNull);
        if (_a.Array(dictionary, "Kids") is not { } kids) return;
        foreach (var kid in kids.Items)
        {
            if (kid is not PdfReference k) continue;
            if (_a.Get(k.Number) is PdfDictionary child && !child.ContainsKey("T")) _widgetFields[k.Number] = reference.Number;
            else Walk(k, name, signature, depth + 1);
        }
    }

    private void ReadLocks(PdfArray references)
    {
        foreach (var item in references.Items)
        {
            if (_a.Resolve(item) is not PdfDictionary reference || _a.Name(reference, "TransformMethod") != "FieldMDP") continue;
            if (_a.Dict(reference, "TransformParams") is not { } parameters) continue;
            var action = _a.Name(parameters, "Action") switch { "Include" => FieldLockAction.Include, "Exclude" => FieldLockAction.Exclude, _ => FieldLockAction.All };
            var names = _a.Array(parameters, "Fields")?.Items.Select(i => PdfText.Read(_a, i)).OfType<string>().ToHashSet() ?? [];
            _locks.Add((action, names));
        }
    }

    private bool IsLocked(string fieldName) => _locks.Any(l => l.Action switch
    {
        FieldLockAction.All => true,
        FieldLockAction.Include => l.Names.Contains(fieldName),
        _ => !l.Names.Contains(fieldName),
    });
}
