namespace LazyPDF.Core;

public sealed partial class StructureTree
{
    /// <summary>
    /// Stores the tree: every element gets its dictionary written (keys this class does not know stay),
    /// the root's /K, /RoleMap, /ClassMap and /ParentTree are rebuilt from the elements, pages and
    /// objects that hold content get a /StructParents or /StructParent key where they have none or
    /// share one with another owner, /MarkInfo /Marked is set and removed elements are freed. A tree
    /// whose parent tree arrays would run past four million slots is an <see cref="InvalidOperationException"/>.
    /// A value that is already what would be written is left alone, so editing one element changes a
    /// few objects, not the whole tree.
    /// </summary>
    public void Write(PdfDocument document)
    {
        if (IsTruncated || ParentSlots() > MaxParentSlots) throw new InvalidOperationException(AccessibilityText.TreeTooLarge);
        var pages = document.Pages;
        Reference ??= document.Add(Dictionary);
        var all = Elements.ToList();
        foreach (var element in all) element.Reference ??= document.Add(element.Dictionary);
        foreach (var element in all) WriteElement(document, element, pages);

        Put(Dictionary, "K", Kids(_roots.Select(r => (PdfObject)r.Reference!).ToList(), Dictionary["K"]));
        Put(Dictionary, "RoleMap", RoleMap.Count == 0 ? null : MapOf(RoleMap.ToDictionary(e => e.Key, e => (PdfObject)new PdfName(e.Value))));
        Put(Dictionary, "ClassMap", ClassMap.Count == 0 ? null : MapOf(ClassMap));
        WriteParentTree(document, all, pages);

        foreach (int number in _removed) document.Delete(number);
        _removed.Clear();

        var catalog = document.Catalog;
        if (catalog["StructTreeRoot"] is not PdfReference current || current.Number != Reference.Number) catalog["StructTreeRoot"] = Reference;
        var info = document.Dict(catalog, "MarkInfo");
        if (info is null) catalog["MarkInfo"] = info = new PdfDictionary();
        if (document.Bool(info, "Marked") != true) info["Marked"] = new PdfBoolean(true);
    }

    // Each page's array in the parent tree runs up to its highest MCID, so a few far-off numbers would allocate a great deal.
    private long ParentSlots() =>
        Contents.GroupBy(c => (c.PageIndex, c.Stream?.Number ?? 0)).Sum(g => g.Max(c => (long)c.Mcid) + 1);

    private void WriteElement(PdfDocument document, StructElement element, IReadOnlyList<PdfPage> pages)
    {
        var d = element.Dictionary;
        if (d["Type"] is null) d["Type"] = new PdfName("StructElem");
        Put(d, "S", element.Type.Length == 0 ? null : new PdfName(element.Type));
        Put(d, "P", element.Parent?.Reference ?? Reference);

        int page = element.PageIndex >= 0 ? element.PageIndex : element.KidList.Select(PageOfKid).FirstOrDefault(p => p >= 0, -1);
        Put(d, "Pg", page >= 0 && page < pages.Count ? pages[page].Reference : null);
        PutText(document, d, "T", element.Title);
        PutText(document, d, "Alt", element.Alt);
        PutText(document, d, "Lang", element.Lang);
        PutText(document, d, "ActualText", element.ActualText);
        PutText(document, d, "ID", element.Id);

        var items = new List<PdfObject>();
        foreach (var kid in element.KidList)
        {
            switch (kid)
            {
                case StructElement child:
                    items.Add(child.Reference!);
                    break;
                case StructContent content when content.Stream is null && content.PageIndex == page:
                    items.Add(new PdfNumber(content.Mcid));
                    break;
                case StructContent content:
                    var mcr = new PdfDictionary { ["Type"] = new PdfName("MCR") };
                    if (content.PageIndex >= 0 && content.PageIndex < pages.Count) mcr["Pg"] = pages[content.PageIndex].Reference;
                    mcr["MCID"] = new PdfNumber(content.Mcid);
                    if (content.Stream is not null) mcr["Stm"] = content.Stream;
                    if (content.StreamOwner is not null) mcr["StmOwn"] = content.StreamOwner;
                    items.Add(mcr);
                    break;
                case StructObject target:
                    var objr = new PdfDictionary { ["Type"] = new PdfName("OBJR") };
                    if (target.PageIndex >= 0 && target.PageIndex < pages.Count) objr["Pg"] = pages[target.PageIndex].Reference;
                    objr["Obj"] = target.Target;
                    items.Add(objr);
                    break;
            }
        }
        Put(d, "K", Kids(items, d["K"]));
    }

    private static int PageOfKid(StructKid kid) => kid switch
    {
        StructContent c => c.PageIndex,
        StructObject o => o.PageIndex,
        _ => -1,
    };

    private void WriteParentTree(PdfDocument document, List<StructElement> all, IReadOnlyList<PdfPage> pages)
    {
        var work = new List<(PdfDictionary Owner, string Name, StructElement Element, StructKid Kid)>();
        foreach (var element in all)
        {
            foreach (var kid in element.KidList)
            {
                if (kid is StructContent content)
                {
                    PdfDictionary? owner = content.Stream is null
                        ? (content.PageIndex >= 0 && content.PageIndex < pages.Count ? pages[content.PageIndex].Dictionary : null)
                        : (document.Resolve(content.Stream) as PdfStream)?.Dictionary;
                    if (owner is not null) work.Add((owner, "StructParents", element, kid));
                }
                else if (kid is StructObject target)
                {
                    var resolved = document.Resolve(target.Target);
                    var owner = resolved is PdfStream s ? s.Dictionary : resolved as PdfDictionary;
                    if (owner is not null) work.Add((owner, "StructParent", element, kid));
                }
            }
        }

        var used = new HashSet<long>();
        foreach (var (owner, name, _, _) in work)
        {
            if (KeyOf(document, owner, name) is { } existingKey) used.Add(existingKey);
        }
        foreach (var page in pages)
        {
            if (KeyOf(document, page.Dictionary, "StructParents") is { } pageKey) used.Add(pageKey);
        }
        var strays = Strays(document, work.Select(w => w.Owner).Concat(pages.Select(p => p.Dictionary)));
        foreach (var (_, _, strayKey) in strays) used.Add(strayKey);
        long next = Math.Max(Math.Min(document.Integer(Dictionary, "ParentTreeNextKey") ?? 0, MaxKey), used.Count > 0 ? used.Max() + 1 : 0);

        // A key stands for one owner; a later owner that carries the same number (pages merged by another tool) gets a new one.
        var owners = new Dictionary<long, PdfDictionary>();
        var assigned = new List<(long Key, StructElement Element, StructKid Kid)>();
        foreach (var (owner, name, element, kid) in work.OrderBy(w => w.Kid is StructObject))
        {
            long key = KeyOf(document, owner, name) ?? -1;
            if (key < 0 || (owners.TryGetValue(key, out var holder) && !ReferenceEquals(holder, owner))) owner[name] = new PdfNumber(key = next++);
            owners[key] = owner;
            assigned.Add((key, element, kid));
        }

        // The parent tree is rebuilt from the elements above, so a number a form or annotation outside them still carries would now lead to another owner's element.
        foreach (var (owner, name, strayKey) in strays)
        {
            if (owners.ContainsKey(strayKey)) owner.Remove(name);
        }

        // A page without tagged content has no use for a key, and one that another owner now holds would point its numbers at that owner's elements.
        foreach (var page in pages)
        {
            if (KeyOf(document, page.Dictionary, "StructParents") is { } pageKey
                && owners.TryGetValue(pageKey, out var holder) && !ReferenceEquals(holder, page.Dictionary))
            {
                page.Dictionary.Remove("StructParents");
            }
        }

        var entries = new SortedDictionary<long, PdfObject>();
        var arrays = new Dictionary<long, List<PdfObject>>();
        foreach (var (key, element, kid) in assigned)
        {
            if (kid is StructContent content)
            {
                if (!arrays.TryGetValue(key, out var list)) arrays[key] = list = [];
                while (list.Count <= content.Mcid) list.Add(PdfNull.Instance);
                list[content.Mcid] = element.Reference!;
            }
            else
            {
                entries[key] = element.Reference!;
            }
        }
        foreach (var (key, list) in arrays) entries[key] = new PdfArray(list);

        var existing = PdfNumberTree.Read(document, Dictionary["ParentTree"]);
        bool same = existing.Count == entries.Count
            && existing.All(e => entries.TryGetValue(e.Key, out var value) && value.ToString() == document.Resolve(e.Value)?.ToString());
        if (!same)
        {
            var root = PdfNumberTree.Write(document, document.Dict(Dictionary, "ParentTree"), entries);
            if (Dictionary["ParentTree"] is null) Dictionary["ParentTree"] = document.Add(root);
        }
        long highest = entries.Count > 0 ? entries.Keys.Max() : -1;
        Put(Dictionary, "ParentTreeNextKey", new PdfNumber(Math.Max(next, highest + 1)));
    }

    // PDF integers stop at 2^31 - 1 (ISO 32000-1 Annex C), so a larger key is no key; it also keeps the next free number from overflowing.
    private const long MaxKey = int.MaxValue;
    private const int MaxAnnotations = 5000;

    private static long? KeyOf(PdfDocument document, PdfDictionary owner, string name) =>
        document.Integer(owner, name) is { } key and >= 0 and <= MaxKey ? key : null;

    // Every object, and the annotations a page holds as direct dictionaries, which no object number leads to.
    private static List<(PdfDictionary Owner, string Name, long Key)> Strays(PdfDocument document, IEnumerable<PdfDictionary> known)
    {
        var skip = new HashSet<PdfDictionary>(known, ReferenceEqualityComparer.Instance);
        var found = new List<(PdfDictionary, string, long)>();
        var candidates = new List<PdfDictionary>();
        foreach (int number in document.ObjectNumbers)
        {
            if (document.Get(number) switch { PdfStream s => s.Dictionary, PdfDictionary plain => plain, _ => null } is { } d) candidates.Add(d);
        }
        foreach (var page in document.Pages)
        {
            if (document.Array(page.Dictionary, "Annots") is not { } annots) continue;
            candidates.AddRange(annots.Items.Take(MaxAnnotations).OfType<PdfDictionary>());
        }
        foreach (var d in candidates)
        {
            if (skip.Contains(d)) continue;
            foreach (string name in (string[])["StructParents", "StructParent"])
            {
                if (KeyOf(document, d, name) is { } key) found.Add((d, name, key));
            }
        }
        return found;
    }

    private static PdfObject? Kids(List<PdfObject> items, PdfObject? current) =>
        items.Count == 0 ? null : items.Count == 1 && current is not PdfArray ? items[0] : new PdfArray(items);

    private static PdfDictionary MapOf(IReadOnlyDictionary<string, PdfObject> map)
    {
        var d = new PdfDictionary();
        foreach (var (key, value) in map) d[key] = value;
        return d;
    }

    private static void Put(PdfDictionary d, string key, PdfObject? value)
    {
        var current = d[key];
        if (value is null)
        {
            if (current is not null) d.Remove(key);
        }
        else if (current is null || current.ToString() != value.ToString())
        {
            d[key] = value;
        }
    }

    private static void PutText(PdfDocument document, PdfDictionary d, string key, string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            d.Remove(key);
            return;
        }
        if (PdfText.Read(document, d, key) != value) d[key] = PdfText.ToObject(value);
    }
}
