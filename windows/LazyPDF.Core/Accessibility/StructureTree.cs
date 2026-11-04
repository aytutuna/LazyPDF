namespace LazyPDF.Core;

/// <summary>
/// The logical structure of a document (ISO 32000-1 14.7, 14.8): the elements under /StructTreeRoot,
/// the role and class maps and the parent tree. A snapshot, as <see cref="Outline"/> is: edit it,
/// then <see cref="Write"/>; it is stale once the session has committed and reopened the document.
/// Reading is tolerant (loops, junk kids, missing /S) and capped; a tree past the caps is read as
/// far as it goes and <see cref="IsTruncated"/> is set, after which it cannot be written.
/// </summary>
public sealed partial class StructureTree
{
    private const int MaxDepth = 128;
    private const int MaxNodes = 1_000_000;
    private const int MaxMcid = 1_000_000;

    private static readonly HashSet<string> Standard = new(StringComparer.Ordinal)
    {
        "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI", "Index", "NonStruct", "Private",
        "P", "H", "L", "LI", "Lbl", "LBody", "Table", "TR", "TH", "TD", "THead", "TBody", "TFoot", "Span", "Quote", "Note",
        "Reference", "BibEntry", "Code", "Link", "Annot", "Ruby", "RB", "RT", "RP", "Warichu", "WT", "WP", "Figure",
        "Formula", "Form",
    };

    private readonly PdfDocument _document;
    private readonly List<StructElement> _roots = [];
    private readonly Dictionary<int, StructElement> _byNumber = [];
    private readonly HashSet<int> _removed = [];
    private readonly Dictionary<int, int> _pageByNumber = [];
    private int _nodes;

    private StructureTree(PdfDocument document, PdfDictionary root, PdfReference? reference)
    {
        _document = document;
        Dictionary = root;
        Reference = reference;
        for (int i = 0; i < document.Pages.Count; i++) _pageByNumber.TryAdd(document.Pages[i].Reference.Number, i);
    }

    /// <summary>The /StructTreeRoot dictionary, live.</summary>
    public PdfDictionary Dictionary { get; }

    public PdfReference? Reference { get; private set; }

    /// <summary>The elements directly under the root, normally one /Document.</summary>
    public IReadOnlyList<StructElement> Roots => _roots;

    /// <summary>Custom type to the type it stands for (14.8.3); change it and write.</summary>
    public Dictionary<string, string> RoleMap { get; } = new(StringComparer.Ordinal);

    /// <summary>Class name to its attribute object (14.7.5.2), as stored.</summary>
    public Dictionary<string, PdfObject> ClassMap { get; } = new(StringComparer.Ordinal);

    /// <summary>The parent tree as stored: key to an array of elements by MCID, or to one element for an object. Values are as in the file.</summary>
    public IReadOnlyList<KeyValuePair<long, PdfObject>> ParentTree { get; private set; } = [];

    /// <summary>The tree has more nodes or levels than the reader takes; it cannot be written.</summary>
    public bool IsTruncated { get; private set; }

    /// <summary>Every element, parents before children.</summary>
    public IEnumerable<StructElement> Elements
    {
        get
        {
            var stack = new Stack<StructElement>(_roots.AsEnumerable().Reverse());
            while (stack.Count > 0)
            {
                var element = stack.Pop();
                yield return element;
                for (int i = element.KidList.Count - 1; i >= 0; i--)
                {
                    if (element.KidList[i] is StructElement child) stack.Push(child);
                }
            }
        }
    }

    public IEnumerable<StructContent> Contents => Elements.SelectMany(e => e.KidList.OfType<StructContent>());

    /// <summary>The tree of a document, or null when it has no /StructTreeRoot.</summary>
    public static StructureTree? Read(PdfDocument document)
    {
        if (document.Dict(document.Catalog, "StructTreeRoot") is not { } root) return null;
        var tree = new StructureTree(document, root, document.Catalog["StructTreeRoot"] as PdfReference);
        tree.ReadAll();
        return tree;
    }

    /// <summary>An empty tree; <see cref="Write"/> adds it to the document.</summary>
    public static StructureTree Create(PdfDocument document)
    {
        var root = new PdfDictionary { ["Type"] = new PdfName("StructTreeRoot") };
        return new StructureTree(document, root, null);
    }

    public static bool IsStandard(string type) =>
        Standard.Contains(type) || (type.Length is >= 2 and <= 4 && type[0] == 'H' && type.AsSpan(1).IndexOfAnyExceptInRange('0', '9') < 0 && type[1] != '0');

    /// <summary>The standard type <paramref name="type"/> stands for through the role map (cycles and chains past 16 stop where they are).</summary>
    public string StandardType(string type)
    {
        for (int i = 0; i < 16 && !IsStandard(type); i++)
        {
            if (!RoleMap.TryGetValue(type, out var next) || next == type) break;
            type = next;
        }
        return type;
    }

    /// <summary>The element the parent tree names for a page's (or form's, or object's) key, and the sequence with that /MCID; for an object pass -1.</summary>
    public StructElement? ElementFor(long key, int mcid)
    {
        foreach (var (k, value) in ParentTree)
        {
            if (k != key) continue;
            var resolved = _document.Resolve(value);
            PdfObject? target = mcid >= 0 && resolved is PdfArray array ? (mcid < array.Items.Count ? array.Items[mcid] : null) : value;
            return target is PdfReference r && _byNumber.TryGetValue(r.Number, out var element) ? element : null;
        }
        return null;
    }

    /// <summary>Puts <paramref name="kid"/> under <paramref name="parent"/> (null: the root) at <paramref name="index"/>, -1 for the end. A kid that is in the tree already is an <see cref="ArgumentException"/>; use <see cref="Move"/>.</summary>
    public void Add(StructElement? parent, StructKid kid, int index = -1)
    {
        if (kid.Parent is not null || _roots.Contains(kid)) throw new ArgumentException(AccessibilityText.AlreadyInTree, nameof(kid));
        if (parent is null && kid is not StructElement) throw new ArgumentException(AccessibilityText.RootNeedsElement, nameof(kid));
        for (var p = parent; p is not null; p = p.Parent)
        {
            if (ReferenceEquals(p, kid)) throw new ArgumentException(AccessibilityText.IntoItself, nameof(parent));
        }
        if (kid is StructElement element) Unmark(element);
        Insert(parent, kid, index);
    }

    /// <summary>Takes <paramref name="kid"/> and what is under it out; the objects of the elements are freed at the next <see cref="Write"/>.</summary>
    public void Remove(StructKid kid)
    {
        Detach(kid);
        if (kid is not StructElement element) return;
        var stack = new Stack<StructElement>([element]);
        while (stack.Count > 0)
        {
            var e = stack.Pop();
            if (e.Reference is { } reference) _removed.Add(reference.Number);
            foreach (var child in e.Children) stack.Push(child);
        }
    }

    /// <summary>Puts <paramref name="kid"/> under <paramref name="parent"/> (null: the root) at <paramref name="index"/> counted after it left its old place; -1 is the end. Reordering is a move inside one parent.</summary>
    public void Move(StructKid kid, StructElement? parent, int index)
    {
        if (parent is null && kid is not StructElement) throw new ArgumentException(AccessibilityText.RootNeedsElement, nameof(kid));
        for (var p = parent; p is not null; p = p.Parent)
        {
            if (ReferenceEquals(p, kid)) throw new ArgumentException(AccessibilityText.IntoItself, nameof(parent));
        }
        Detach(kid);
        Insert(parent, kid, index);
    }

    private void Insert(StructElement? parent, StructKid kid, int index)
    {
        if (parent is null)
        {
            var list = _roots;
            list.Insert(index < 0 || index > list.Count ? list.Count : index, (StructElement)kid);
        }
        else
        {
            var list = parent.KidList;
            list.Insert(index < 0 || index > list.Count ? list.Count : index, kid);
        }
        kid.Parent = parent;
    }

    private void Detach(StructKid kid)
    {
        if (kid.Parent is { } parent) parent.KidList.Remove(kid);
        else if (kid is StructElement element) _roots.Remove(element);
        kid.Parent = null;
    }

    private void Unmark(StructElement element)
    {
        var stack = new Stack<StructElement>([element]);
        while (stack.Count > 0)
        {
            var e = stack.Pop();
            if (e.Reference is { } reference) _removed.Remove(reference.Number);
            foreach (var child in e.Children) stack.Push(child);
        }
    }

    private void ReadAll()
    {
        var kids = new List<StructKid>();
        ReadKid(Dictionary["K"], null, -1, 0, kids);
        foreach (var kid in kids.OfType<StructElement>())
        {
            kid.Parent = null;
            _roots.Add(kid);
        }

        if (_document.Dict(Dictionary, "RoleMap") is { } roles)
        {
            foreach (var (key, value) in roles.Entries.Take(10_000))
            {
                if (_document.Resolve(value) is PdfName name) RoleMap[key] = name.Value;
            }
        }
        if (_document.Dict(Dictionary, "ClassMap") is { } classes)
        {
            foreach (var (key, value) in classes.Entries.Take(10_000)) ClassMap[key] = value;
        }
        ParentTree = PdfNumberTree.Read(_document, Dictionary["ParentTree"]);
    }

    private void ReadKid(PdfObject? item, StructElement? parent, int page, int depth, List<StructKid> into)
    {
        if (item is PdfArray list)
        {
            foreach (var entry in list.Items.Take(MaxNodes)) ReadKid(entry, parent, page, depth, into);
            return;
        }
        if (++_nodes > MaxNodes || depth > MaxDepth)
        {
            IsTruncated = true;
            return;
        }

        var value = _document.Resolve(item);
        if (value is PdfArray resolvedList)
        {
            ReadKid(resolvedList, parent, page, depth + 1, into);
            return;
        }
        if (value is PdfNumber { Integer: { } mcid })
        {
            if (mcid is >= 0 and <= MaxMcid) into.Add(new StructContent(page, (int)mcid) { Parent = parent });
            return;
        }
        if (value is not PdfDictionary d) return;

        string? kind = _document.Name(d, "Type");
        int own = PageOf(d["Pg"]);
        if (kind == "MCR" || (d.ContainsKey("MCID") && !d.ContainsKey("S")))
        {
            if (_document.Integer(d, "MCID") is >= 0 and <= MaxMcid and var id)
            {
                into.Add(new StructContent(own >= 0 ? own : page, (int)id, d["Stm"] as PdfReference) { Parent = parent });
            }
            return;
        }
        if (kind == "OBJR" || (d.ContainsKey("Obj") && !d.ContainsKey("S")))
        {
            if (d["Obj"] is PdfReference target) into.Add(new StructObject(own >= 0 ? own : page, target) { Parent = parent });
            return;
        }

        var reference = item as PdfReference;
        if (reference is not null && _byNumber.ContainsKey(reference.Number)) return;
        var element = new StructElement(_document.Name(d, "S") ?? "", d, reference)
        {
            Title = PdfText.Read(_document, d, "T"),
            Alt = PdfText.Read(_document, d, "Alt"),
            Lang = PdfText.Read(_document, d, "Lang"),
            ActualText = PdfText.Read(_document, d, "ActualText"),
            Id = PdfText.Read(_document, d, "ID"),
            PageIndex = own,
            Parent = parent,
        };
        if (reference is not null) _byNumber[reference.Number] = element;
        var children = new List<StructKid>();
        ReadKid(d["K"], element, own >= 0 ? own : page, depth + 1, children);
        element.KidList.AddRange(children);
        into.Add(element);
    }

    private int PageOf(PdfObject? reference) =>
        reference is PdfReference r && _pageByNumber.TryGetValue(r.Number, out int index) ? index : -1;
}
