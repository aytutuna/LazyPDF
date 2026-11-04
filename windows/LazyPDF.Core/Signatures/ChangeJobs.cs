namespace LazyPDF.Core;

internal enum JobKind
{
    Trailer,
    Plain,
    Content,
    Structure,
    Link,
    Catalog,
    PageTree,
    Page,
    AnnotList,
    Comment,
    Form,
    FieldList,
    Field,
    Appearance,
    Value,
    Info,
    Dss,
    Action,
    Defaults,
}

/// <summary>One thing an object is used for. <paramref name="Owner"/> is the field a drawing or value belongs to (0 for a comment), the depth in /DSS for validation data.</summary>
internal readonly record struct Job(JobKind Kind, int Owner = 0, int Page = -1);

internal sealed record FieldNode(int Number, string Name, bool IsSignature, bool HasValue, int Parent = 0);

// The jobs of every object of a document, from one walk over all of it starting at the trailer. A key leads to a
// job through the tables in Child and Element; every other key leads to a plain use, which no level lets change.
// Plumbing that only names an object (/CO, the fields of SubmitForm and ResetForm, /T of Hide, /Data of a signature
// reference, the page of a destination) is not a use of it. A /Parent names its object only where that object lists
// the child back; /Parent also carries inheritance (7.7.3.4, 12.7.3.1), so any other is a use.
internal sealed class Jobs
{
    private const int MaxVisits = 5_000_000;
    private const int MaxDepth = 32;
    private const int MaxFields = 200_000;

    private readonly PdfDocument _document;
    private readonly Dictionary<int, HashSet<Job>> _jobs = [];
    private readonly HashSet<(int, Job)> _seen = [];
    private readonly HashSet<int> _roles = [];
    private readonly Dictionary<int, int> _pageIndex = [];
    private readonly Dictionary<int, int> _widgetField = [];
    private readonly HashSet<(int Child, int Parent)> _listed = [];

    public Dictionary<int, FieldNode> Fields { get; } = [];

    /// <summary>False when a cap ended the walk early: the jobs found are then not all there are.</summary>
    public bool Complete { get; private set; } = true;

    public Jobs(PdfDocument document)
    {
        _document = document;
        for (int i = 0; i < document.Pages.Count; i++)
        {
            if (document.Pages[i].Reference is { } page)
            {
                _pageIndex[page.Number] = i;
                _roles.Add(page.Number);
            }
            foreach (var annot in document.Array(document.Pages[i].Dictionary, "Annots")?.Items.OfType<PdfReference>() ?? [])
            {
                _roles.Add(annot.Number);
                if (document.Get(annot.Number) is PdfDictionary dictionary && dictionary["Popup"] is PdfReference popup) _listed.Add((popup.Number, annot.Number));
            }
        }
        if (document.Dict(document.Catalog, "AcroForm") is { } form && document.Array(form, "Fields") is { } fields)
        {
            foreach (var item in fields.Items.OfType<PdfReference>()) IndexField(item, "", false, 0, 0);
        }
        _roles.UnionWith(Fields.Keys);
        _roles.UnionWith(_widgetField.Keys);
        IndexTree();
        Walk();
    }

    public IReadOnlySet<Job> Of(int number) => _jobs.TryGetValue(number, out var jobs) ? jobs : [];

    private void IndexField(PdfReference reference, string prefix, bool inheritedSignature, int depth, int parent)
    {
        if (depth > MaxDepth || Fields.Count > MaxFields)
        {
            Complete = false;
            return;
        }
        if (Fields.ContainsKey(reference.Number) || _document.Get(reference.Number) is not PdfDictionary dictionary) return;
        string name = PdfText.Read(_document, dictionary["T"]) is { } partial ? prefix.Length == 0 ? partial : prefix + "." + partial : prefix;
        bool signature = _document.Name(dictionary, "FT") is { } type ? type == "Sig" : inheritedSignature || SigUpwards(dictionary);
        Fields[reference.Number] = new FieldNode(reference.Number, name, signature, dictionary["V"] is not null and not PdfNull, parent);
        if (_document.Array(dictionary, "Kids") is not { } kids) return;
        foreach (var kid in kids.Items.OfType<PdfReference>())
        {
            _listed.Add((kid.Number, reference.Number));
            if (_document.Get(kid.Number) is PdfDictionary child && !child.ContainsKey("T")) _widgetField[kid.Number] = reference.Number;
            else IndexField(kid, name, signature, depth + 1, reference.Number);
        }
    }

    // A reader takes the type from the /Parent chain whether or not a /Kids array lists the field there (12.7.3.1).
    private bool SigUpwards(PdfDictionary field)
    {
        for (int i = 0; i < MaxDepth && _document.Dict(field, "Parent") is { } parent; i++, field = parent)
        {
            if (_document.Name(parent, "FT") is { } type) return type == "Sig";
        }
        return false;
    }

    // The nodes of the page tree are named by their pages' /Parent, which is not a use of them.
    private void IndexTree()
    {
        var pending = new Stack<PdfObject?>();
        pending.Push(_document.Catalog["Pages"]);
        for (int visits = 0; pending.Count > 0 && visits < MaxFields; visits++)
        {
            if (pending.Pop() is not PdfReference r || !_roles.Add(r.Number) || _document.Get(r.Number) is not PdfDictionary node) continue;
            foreach (var kid in _document.Array(node, "Kids")?.Items ?? [])
            {
                pending.Push(kid);
                if (kid is PdfReference k) _listed.Add((k.Number, r.Number));
            }
        }
        if (pending.Count > 0) Complete = false;
    }

    private void Walk()
    {
        int catalog = (_document.Trailer["Root"] as PdfReference)?.Number ?? 0;
        var pending = new Stack<(PdfObject Value, Job Context, int From)>();
        pending.Push((_document.Trailer, new Job(JobKind.Trailer), 0));
        while (pending.Count > 0 && _seen.Count < MaxVisits)
        {
            var (value, context, from) = pending.Pop();
            switch (value)
            {
                case PdfReference r:
                    Visit(r, context, pending);
                    break;
                case PdfArray array:
                    foreach (var item in array.Items.Skip(NamesPage(array, context) ? 1 : 0)) pending.Push((item, Element(context, item), from));
                    break;
                case PdfDictionary dictionary:
                    foreach (var (key, item) in dictionary.Entries)
                    {
                        if (NamesFields(dictionary, context, key, item, catalog) || Child(context, key) is not { } next) continue;
                        if (next.Kind == JobKind.Link && key == "Parent" && !(item is PdfReference p && _listed.Contains((from, p.Number)))) next = new Job(JobKind.Plain);
                        pending.Push((item, next, from));
                    }
                    break;
                case PdfStream stream:
                    pending.Push((stream.Dictionary, context, from));
                    break;
            }
        }
        if (pending.Count > 0) Complete = false;
    }

    private void Visit(PdfReference r, Job context, Stack<(PdfObject, Job, int)> pending)
    {
        // The back links name pages, annotations and fields; what they name keeps its own job.
        bool naming = context.Kind == JobKind.Link;
        if (naming && _roles.Contains(r.Number) || !_seen.Add((r.Number, context))) return;
        var job = naming || context.Kind == JobKind.Action ? new Job(JobKind.Plain) : context;
        if (!_jobs.TryGetValue(r.Number, out var jobs)) _jobs[r.Number] = jobs = [];
        jobs.Add(job);
        if (_document.Get(r.Number) is { } target) pending.Push((target, context.Kind == JobKind.Link ? job : context, r.Number));
    }

    // Plumbing that only names: the fields of a real SubmitForm or ResetForm action and the target of Hide, which are
    // found under /A, /AA and /OpenAction (12.6.4), and the catalog a signature reference signs (12.8.1).
    private static bool NamesFields(PdfDictionary dictionary, Job context, string key, PdfObject item, int catalog) =>
        context.Kind == JobKind.Action && (key, dictionary["S"]) is ("Fields", PdfName { Value: "SubmitForm" or "ResetForm" }) or ("T", PdfName { Value: "Hide" })
        || key == "Data" && dictionary.ContainsKey("TransformMethod") && item is PdfReference r && r.Number == catalog;

    // A destination names its page (12.3.2.2) without using it.
    private bool NamesPage(PdfArray array, Job context) =>
        context.Kind is JobKind.Plain or JobKind.Action
        && array.Items is [PdfReference page, PdfName { Value: "XYZ" or "Fit" or "FitH" or "FitV" or "FitR" or "FitB" or "FitBH" or "FitBV" }, ..]
        && _pageIndex.ContainsKey(page.Number);

    // What an entry of an array is, given what the array is.
    private Job Element(Job context, PdfObject item)
    {
        var target = _document.Resolve(item) as PdfDictionary;
        int number = (item as PdfReference)?.Number ?? 0;
        switch (context.Kind)
        {
            case JobKind.PageTree:
                bool leaf = target is not null && (_document.Name(target, "Type") == "Page" || !target.ContainsKey("Kids"));
                return leaf ? new Job(JobKind.Page, 0, _pageIndex.GetValueOrDefault(number, -1)) : context;
            case JobKind.AnnotList:
                return target is not null && _document.Name(target, "Subtype") == "Widget"
                    ? new Job(JobKind.Field, OwnerOf(number, target, NamedParent(target)), context.Page)
                    : new Job(JobKind.Comment, 0, context.Page);
            case JobKind.FieldList:
                return new Job(JobKind.Field, OwnerOf(number, target, context.Owner), context.Page);
            default:
                return context;
        }
    }

    // A widget that is not a field of its own answers for the field above it only when it adds nothing a reader reads as
    // its own: a name, a type, flags or kids, or a /Parent that is not that field (12.7.3.1). Any other has no owner.
    private int OwnerOf(int number, PdfDictionary? widget, int fallback)
    {
        if (Fields.ContainsKey(number)) return number;
        int owner = _widgetField.GetValueOrDefault(number, fallback);
        bool own = widget is null || widget.ContainsKey("T") || widget.ContainsKey("FT") || widget.ContainsKey("Ff") || widget.ContainsKey("Kids")
            || widget["Parent"] is { } parent && !(parent is PdfReference p && p.Number == owner);
        return own ? -1 : owner;
    }

    // A widget that no field lists belongs to the field it names as its parent, so that it is judged with it.
    private int NamedParent(PdfDictionary widget) => widget["Parent"] is PdfReference p && Fields.ContainsKey(p.Number) ? p.Number : -1;

    // What the value under a key of a dictionary is, given what the dictionary is; null for a key that leads nowhere.
    private static Job? Child(Job context, string key)
    {
        var (kind, owner, page) = context;
        switch (kind)
        {
            case JobKind.Trailer:
                return new Job(key switch { "Root" => JobKind.Catalog, "Info" => JobKind.Info, _ => JobKind.Plain });
            case JobKind.Catalog:
                return key switch
                {
                    "Pages" => new Job(JobKind.PageTree),
                    "Metadata" => new Job(JobKind.Info),
                    "DSS" => new Job(JobKind.Dss),
                    "AcroForm" => new Job(JobKind.Form),
                    "StructTreeRoot" => new Job(JobKind.Structure),
                    "OpenAction" or "AA" => new Job(JobKind.Action),
                    _ => new Job(JobKind.Plain),
                };
            case JobKind.PageTree:
                return key switch { "Kids" => context, "Parent" => new Job(JobKind.Link), _ => new Job(JobKind.Content) };
            // Where the structure tree names a page, an annotation or a field (14.7.4.3), it does not use it.
            case JobKind.Structure:
                return key is "Pg" or "Obj" ? new Job(JobKind.Link) : context;
            // A bead names its page (12.4.3).
            case JobKind.Plain or JobKind.Content when key == "P":
                return new Job(JobKind.Link);
            case JobKind.Defaults:
                return new Job(JobKind.Defaults, owner == 0 && key == "Font" ? 1 : 2);
            case JobKind.Page:
                return key switch
                {
                    "Annots" => new Job(JobKind.AnnotList, 0, page),
                    "Parent" => new Job(JobKind.Link),
                    "AA" => new Job(JobKind.Action),
                    _ => new Job(JobKind.Content, 0, page),
                };
            case JobKind.Form:
                return key switch { "Fields" => new Job(JobKind.FieldList), "DR" => new Job(JobKind.Defaults), "CO" => null, _ => new Job(JobKind.Plain) };
            case JobKind.Field:
                return key switch
                {
                    "Kids" => new Job(JobKind.FieldList, owner, page),
                    "AP" => new Job(JobKind.Appearance, owner, page),
                    "V" => new Job(JobKind.Value, owner, page),
                    "Parent" or "P" or "Popup" or "IRT" => new Job(JobKind.Link),
                    "A" or "AA" => new Job(JobKind.Action),
                    _ => new Job(JobKind.Plain),
                };
            case JobKind.Comment:
                return key switch
                {
                    "AP" => new Job(JobKind.Appearance, 0, page),
                    "Parent" or "P" or "Popup" or "IRT" => new Job(JobKind.Link),
                    "A" or "AA" => new Job(JobKind.Action),
                    _ => new Job(JobKind.Plain),
                };
            case JobKind.Plain when key is "A" or "AA" or "OpenAction":
                return new Job(JobKind.Action);
            case JobKind.Dss:
                return DssChild(owner, key);
            case JobKind.AnnotList or JobKind.FieldList:
                return new Job(JobKind.Plain);
            default:
                return context;
        }
    }

    // /DSS (depth 0) holds the lists and /VRI (1); /VRI holds an entry for each signature (2); an entry holds lists (3), as do the lists.
    private static Job? DssChild(int depth, string key) => depth switch
    {
        0 when key is "Certs" or "OCSPs" or "CRLs" => new Job(JobKind.Dss, 3),
        0 when key == "VRI" => new Job(JobKind.Dss, 1),
        1 when key.Length == 40 && key.All(char.IsAsciiHexDigit) => new Job(JobKind.Dss, 2),
        2 when key is "Cert" or "OCSP" or "CRL" or "TS" => new Job(JobKind.Dss, 3),
        3 => new Job(JobKind.Dss, 3),
        _ => new Job(JobKind.Plain),
    };
}
