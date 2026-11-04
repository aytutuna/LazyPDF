namespace LazyPDF.Core;

/// <summary>One bookmark (ISO 32000-1 12.3.3). Change the properties freely and call <see cref="Outline.Write"/>; the tree itself is changed through the <see cref="Outline"/>.</summary>
public sealed class OutlineItem
{
    private readonly List<OutlineItem> _children = [];

    public string Title { get; set; } = "";

    /// <summary>Where it goes: /Dest, or the destination of a GoTo action.</summary>
    public PdfDestination? Destination { get; set; }

    /// <summary>The /A action, whatever it is.</summary>
    public PdfAction? Action { get; set; }

    /// <summary>Text colour, each part 0 to 1; null for the viewer's own.</summary>
    public (double R, double G, double B)? Color { get; set; }

    public bool Bold { get; set; }
    public bool Italic { get; set; }

    /// <summary>The children show in the panel.</summary>
    public bool IsOpen { get; set; }

    public OutlineItem? Parent { get; internal set; }

    public IReadOnlyList<OutlineItem> Children => _children;

    internal List<OutlineItem> ChildList => _children;

    // What was read, so that a write leaves unknown keys, and a destination or action nobody touched, as they were.
    internal PdfReference? Reference { get; set; }
    internal PdfDictionary? Source { get; set; }
    internal PdfDestination? ReadDestination { get; set; }
    internal PdfAction? ReadAction { get; set; }
}

/// <summary>
/// The bookmark tree of a document. <see cref="Read"/> takes a snapshot, the editing methods
/// change it, <see cref="Write"/> puts it back into the document: items keep their objects and
/// every key not listed here, removed ones are freed, /Count is worked out again. A snapshot is
/// stale once the document is saved through an edit session and reopened.
/// </summary>
public sealed class Outline
{
    private const int MaxItems = 100_000;
    private const int MaxDepth = 64;

    private readonly HashSet<int> _read = [];

    private Outline() { }

    /// <summary>The top level; its children are the first row of bookmarks. Not written as an item.</summary>
    public OutlineItem Root { get; } = new() { IsOpen = true };

    public IReadOnlyList<OutlineItem> Items => Root.Children;

    /// <summary>
    /// Reads /Outlines. A chain that loops, an item met twice, more than 100000 items or a tree
    /// deeper than 64 levels is cut off there.
    /// </summary>
    public static Outline Read(PdfDocument document)
    {
        var outline = new Outline();
        if (document.Dict(document.Catalog, "Outlines") is not { } top) return outline;
        outline.Root.Source = top;
        outline.Root.Reference = document.Catalog["Outlines"] as PdfReference;
        var context = new DestContext(document);
        var seen = new HashSet<int>();
        if (outline.Root.Reference is { } topReference) seen.Add(topReference.Number);
        int count = 0;
        Fill(outline.Root, top, 0);
        return outline;

        void Fill(OutlineItem parent, PdfDictionary dictionary, int depth)
        {
            if (depth >= MaxDepth) return;
            var link = dictionary["First"];
            while (link is not null && count < MaxItems)
            {
                if (link is PdfReference r && !seen.Add(r.Number)) return;
                if (document.Resolve(link) is not PdfDictionary node) return;
                count++;
                var item = ReadItem(document, node, link as PdfReference, context);
                item.Parent = parent;
                parent.ChildList.Add(item);
                if (item.Reference is { } known) outline._read.Add(known.Number);
                Fill(item, node, depth + 1);
                link = node["Next"];
            }
        }
    }

    private static OutlineItem ReadItem(PdfDocument document, PdfDictionary node, PdfReference? reference, DestContext context)
    {
        var item = new OutlineItem
        {
            Title = PdfText.Read(document, node, "Title") ?? "",
            Reference = reference,
            Source = node,
            IsOpen = document.Integer(node, "Count") is > 0,
        };
        if (document.Array(node, "C") is { Items.Count: 3 } color
            && color.Items.Select(i => document.Resolve(i) as PdfNumber).ToArray() is [{ } r, { } g, { } b])
        {
            item.Color = (Math.Clamp(r.Value, 0, 1), Math.Clamp(g.Value, 0, 1), Math.Clamp(b.Value, 0, 1));
        }
        long flags = document.Integer(node, "F") ?? 0;
        item.Italic = (flags & 1) != 0;
        item.Bold = (flags & 2) != 0;
        item.ReadAction = PdfActions.Read(document, node["A"], context);
        item.Action = item.ReadAction;
        item.ReadDestination = node.ContainsKey("Dest")
            ? PdfDestinations.Parse(document, node["Dest"], context)
            : (item.ReadAction as GoToAction)?.Destination;
        item.Destination = item.ReadDestination;
        return item;
    }

    /// <summary>Adds <paramref name="item"/> under <paramref name="parent"/> (the top level when null) at <paramref name="index"/>, the end by default.</summary>
    public OutlineItem Add(OutlineItem item, OutlineItem? parent = null, int index = -1)
    {
        parent ??= Root;
        if (item.Parent is not null || Contains(item, parent)) throw new ArgumentException("The item is already in a tree, or is the parent's ancestor.", nameof(item));
        Insert(item, parent, index);
        return item;
    }

    /// <summary>Takes the item, with its children, out of the tree. They are freed at the next write.</summary>
    public void Remove(OutlineItem item)
    {
        item.Parent?.ChildList.Remove(item);
        item.Parent = null;
    }

    /// <summary>Moves the item, with its children, under <paramref name="parent"/> (the top level when null) at <paramref name="index"/>. Throws when the parent is the item or inside it.</summary>
    public void Move(OutlineItem item, OutlineItem? parent, int index = -1)
    {
        parent ??= Root;
        if (item.Parent is null) throw new ArgumentException("The item is not in the tree.", nameof(item));
        if (Contains(item, parent)) throw new ArgumentException("An item cannot move into itself.", nameof(parent));
        var old = item.Parent;
        int at = old.ChildList.IndexOf(item);
        old.ChildList.RemoveAt(at);
        // Removing it from the same parent shifts the places after it.
        if (ReferenceEquals(old, parent) && index > at) index--;
        Insert(item, parent, index);
    }

    private static void Insert(OutlineItem item, OutlineItem parent, int index)
    {
        if (index < 0 || index > parent.ChildList.Count) index = parent.ChildList.Count;
        parent.ChildList.Insert(index, item);
        item.Parent = parent;
    }

    private static bool Contains(OutlineItem item, OutlineItem candidate)
    {
        for (var at = candidate; at is not null; at = at.Parent)
        {
            if (ReferenceEquals(at, item)) return true;
        }
        return false;
    }

    /// <summary>
    /// Stores the tree in the document. With no items /Outlines is taken out of the catalog and
    /// freed. An item whose destination refers to a page that is not there keeps the old one.
    /// </summary>
    public void Write(PdfDocument document)
    {
        var written = new HashSet<int>();
        if (Root.Children.Count == 0)
        {
            document.Catalog.Remove("Outlines");
        }
        else
        {
            Root.Source ??= new PdfDictionary();
            if (!Alive(document, Root)) Root.Reference = document.Add(Root.Source);
            Root.Source["Type"] = new PdfName("Outlines");
            document.Catalog["Outlines"] = Root.Reference;
            written.Add(Root.Reference!.Number);
            int visible = Link(document, Root, written);
            SetCount(Root.Source, visible);
        }
        foreach (int number in _read.Concat(RootNumber()).Where(n => !written.Contains(n)).ToList())
        {
            document.Delete(number);
            _read.Remove(number);
        }
        foreach (int number in written) _read.Add(number);
    }

    // An item freed by an earlier write still holds its old reference.
    private static bool Alive(PdfDocument document, OutlineItem item) =>
        item.Reference is { } reference && ReferenceEquals(document.Resolve(reference), item.Source);

    private IEnumerable<int> RootNumber() => Root.Reference is { } r ? [r.Number] : [];

    // Writes the children of a parent and returns how many rows they show (12.3.3: the visible descendants, counting a closed item's as none).
    private static int Link(PdfDocument document, OutlineItem parent, HashSet<int> written)
    {
        var children = parent.Children;
        foreach (var child in children)
        {
            child.Source ??= new PdfDictionary();
            if (!Alive(document, child)) child.Reference = document.Add(child.Source);
            written.Add(child.Reference!.Number);
        }
        int visible = 0;
        for (int i = 0; i < children.Count; i++)
        {
            var child = children[i];
            var d = child.Source!;
            d["Title"] = PdfText.ToObject(child.Title);
            d["Parent"] = parent.Reference!;
            SetLink(d, "Prev", i > 0 ? children[i - 1].Reference : null);
            SetLink(d, "Next", i < children.Count - 1 ? children[i + 1].Reference : null);
            SetTarget(document, child);
            SetStyle(child);

            int below = Link(document, child, written);
            SetCount(d, child.IsOpen ? below : -below);
            visible += 1 + (child.IsOpen ? below : 0);
        }
        var holder = parent.Source!;
        SetLink(holder, "First", children.Count > 0 ? children[0].Reference : null);
        SetLink(holder, "Last", children.Count > 0 ? children[^1].Reference : null);
        return visible;
    }

    private static void SetLink(PdfDictionary d, string key, PdfReference? target)
    {
        if (target is null) d.Remove(key);
        else d[key] = target;
    }

    private static void SetCount(PdfDictionary d, int count)
    {
        if (count == 0) d.Remove("Count");
        else d["Count"] = new PdfNumber(count);
    }

    private static void SetTarget(PdfDocument document, OutlineItem item)
    {
        var d = item.Source!;
        if (!ReferenceEquals(item.Action, item.ReadAction))
        {
            d.Remove("A");
            if (item.Action is { } action)
            {
                d["A"] = PdfActions.ToObject(document, action);
                d.Remove("Dest");
            }
        }
        if (!ReferenceEquals(item.Destination, item.ReadDestination))
        {
            if (item.Destination is null)
            {
                d.Remove("Dest");
                if (item.Action is GoToAction && ReferenceEquals(item.Action, item.ReadAction))
                {
                    d.Remove("A");
                    item.Action = null;
                }
            }
            else if (PdfDestinations.ToObject(document, item.Destination) is { } value)
            {
                d["Dest"] = value;
                d.Remove("A");
            }
        }
        item.ReadAction = item.Action;
        item.ReadDestination = item.Destination;
    }

    private static void SetStyle(OutlineItem item)
    {
        var d = item.Source!;
        if (item.Color is { } c) d["C"] = new PdfArray([new PdfNumber(c.R), new PdfNumber(c.G), new PdfNumber(c.B)]);
        else d.Remove("C");
        int flags = (item.Italic ? 1 : 0) | (item.Bold ? 2 : 0);
        if (flags == 0) d.Remove("F");
        else d["F"] = new PdfNumber(flags);
    }
}
