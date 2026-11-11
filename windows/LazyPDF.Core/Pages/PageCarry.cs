namespace LazyPDF.Core;

// What a new document keeps of the source besides the pages: the bookmarks, labels, named
// destinations, attached files and tag tree of the pages taken, and the language and XMP of the document.
// Runs once the pages are in the target's tree, since destinations are written by page index.
internal static class PageCarry
{
    private const int MaxTagElements = 200_000;

    /// <summary>
    /// Carries what belongs to the source pages at <paramref name="sourcePages"/>, which are the target's pages from
    /// <paramref name="firstNewIndex"/> on. <paramref name="mergeTitle"/> is set for one source of a merge: its bookmarks go under an item with that title and no labels are written.
    /// </summary>
    public static void Carry(PdfDocument source, PdfDocument target, IReadOnlyList<int> sourcePages, int firstNewIndex, string? mergeTitle = null, bool files = true)
    {
        var newIndex = new Dictionary<int, int>();
        for (int i = 0; i < sourcePages.Count; i++) newIndex.TryAdd(sourcePages[i], firstNewIndex + i);
        Bookmarks(source, target, newIndex, mergeTitle);
        if (mergeTitle is null) Labels(source, target, sourcePages);
        NamedDestinations(source, target, newIndex);
        foreach (var file in files ? PdfAttachments.List(source).Where(a => a.PageIndex is null) : [])
        {
            byte[] data;
            try { data = PdfAttachments.Extract(source, file); }
            catch (Exception e) when (e is PdfReadException or InvalidOperationException) { target.SkippedAttachments++; continue; }
            PdfAttachments.Add(target, file.FileName, data, file.MimeType, file.Description, file.Created, file.Modified);
        }
    }

    /// <summary>The source's /Lang, and its XMP when the target has the /Info as well, without its PDF/A and PDF/UA claims.</summary>
    public static void Catalog(PdfDocument source, PdfDocument target, PageImporter importer)
    {
        if (source.Catalog["Lang"] is { } lang) target.Catalog["Lang"] = importer.CopyValue(lang);
        if (target.Trailer["Info"] is null || source.Catalog["Metadata"] is not { } xmp) return;
        target.Catalog["Metadata"] = importer.CopyValue(xmp);
        DropConformance(target);
    }

    // Part of a PDF/A file is not PDF/A: the copy was not checked and the pages lost what the claim covers.
    private static void DropConformance(PdfDocument target)
    {
        if (target.Stream(target.Catalog, "Metadata") is not { } stream || XmpPacket.Load(target) is not { } packet) return;
        bool a = packet.RemoveProperties(XmpPacket.PdfAId);
        bool ua = packet.RemoveProperties(XmpPacket.PdfUAId);
        if (!a && !ua) return;
        stream.Data = packet.ToBytes();
        stream.Dictionary.Remove("Filter");
        stream.Dictionary.Remove("DecodeParms");
    }

    /// <summary>Whether the source has a tag tree small enough to carry.</summary>
    public static bool HasTags(PdfDocument source)
    {
        if (source.Dict(source.Catalog, "StructTreeRoot") is not { } root) return false;
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var open = new Stack<PdfDictionary>();
        open.Push(root);
        while (open.TryPop(out var element))
        {
            if (!seen.Add(element)) continue;
            if (seen.Count >= MaxTagElements) return false;
            var kids = source.Resolve(element["K"]);
            foreach (var kid in kids is PdfArray array ? array.Items : kids is null ? [] : [kids])
            {
                if (source.Resolve(kid) is PdfDictionary child) open.Push(child);
            }
        }
        return true;
    }

    /// <summary>The source's tag tree cut to the pages taken, which <paramref name="copies"/> are the copies of; the importer kept their keys.</summary>
    public static void Tags(PdfDocument source, PdfDocument target, PageImporter importer, IReadOnlyList<PdfReference> copies)
    {
        Pruned(source, target, importer, copies);
        if (source.Catalog["MarkInfo"] is { } mark) target.Catalog["MarkInfo"] = importer.CopyValue(mark);
    }

    /// <summary>
    /// One tag tree for a merge: the kids of each source's pruned tree under a new root, with the keys of the later
    /// sources moved past those of the earlier. <paramref name="all"/> is whether every source with pages is in <paramref name="tagged"/>.
    /// </summary>
    public static void MergeTags(PdfDocument target, IReadOnlyList<(PdfDocument Source, PageImporter Importer, IReadOnlyList<PdfReference> Copies)> tagged, bool all)
    {
        if (tagged.Count == 0) return;
        var root = new PdfDictionary { ["Type"] = new PdfName("StructTreeRoot") };
        var rootRef = target.Add(root);
        var kids = new List<PdfObject>();
        var roles = new PdfDictionary();
        var parents = new List<KeyValuePair<long, PdfObject>>();
        long next = 0;
        foreach (var (source, importer, copies) in tagged)
        {
            var tree = Pruned(source, target, importer, copies);
            long end = next;
            foreach (var (holder, key) in Holders(target, copies))
            {
                if (target.Integer(holder, key) is not { } number) continue;
                holder[key] = new PdfNumber(number + next);
                end = Math.Max(end, number + next + 1);
            }
            foreach (var (key, value) in PdfNumberTree.Read(target, tree["ParentTree"]))
            {
                parents.Add(new(key + next, value));
                end = Math.Max(end, key + next + 1);
            }
            next = end;
            var own = tree["K"];
            foreach (var kid in target.Resolve(own) is PdfArray array ? array.Items : own is null ? [] : [own])
            {
                if (target.Resolve(kid) is PdfDictionary element && element.ContainsKey("P")) element["P"] = rootRef;
                kids.Add(kid);
            }
            if (target.Dict(tree, "RoleMap") is { } map)
            {
                foreach (var (name, role) in map.Entries)
                {
                    if (!roles.ContainsKey(name)) roles[name] = role;
                }
            }
        }
        root["K"] = new PdfArray(kids);
        root["ParentTree"] = target.Add(PdfNumberTree.Write(target, null, parents));
        root["ParentTreeNextKey"] = new PdfNumber(next);
        if (roles.Count > 0) root["RoleMap"] = roles;
        target.Catalog["StructTreeRoot"] = rootRef;
        if (all) target.Catalog["MarkInfo"] = new PdfDictionary { ["Marked"] = new PdfBoolean(true) };
    }

    // The tree is the catalog's until a merge replaces it, since the pruner works on the catalog's.
    private static PdfDictionary Pruned(PdfDocument source, PdfDocument target, PageImporter importer, IReadOnlyList<PdfReference> copies)
    {
        var ghost = target.Add(new PdfDictionary { ["Type"] = new PdfName("Page") });
        target.Catalog["StructTreeRoot"] = importer.CopyTree(source.Catalog["StructTreeRoot"]!, ghost);
        RedactionStructure.Prune(target, [], [], [ghost.Number]);
        target.Delete(ghost.Number);
        var root = target.Dict(target.Catalog, "StructTreeRoot")!;
        var used = Holders(target, copies).Select(h => target.Integer(h.Holder, h.Key)).OfType<long>().ToHashSet();
        if (target.Dict(root, "ParentTree") is { } parents)
        {
            PdfNumberTree.Write(target, parents, PdfNumberTree.Read(target, parents).Where(e => used.Contains(e.Key)).ToList());
        }
        return root;
    }

    // Where a key into the parent tree is written: the pages and their annotations.
    private static IEnumerable<(PdfDictionary Holder, string Key)> Holders(PdfDocument target, IReadOnlyList<PdfReference> copies)
    {
        foreach (var copy in copies)
        {
            if (target.Resolve(copy) is not PdfDictionary page) continue;
            yield return (page, "StructParents");
            foreach (var item in target.Array(page, "Annots")?.Items ?? [])
            {
                if (target.Resolve(item) is PdfDictionary annotation) yield return (annotation, "StructParent");
            }
        }
    }

    /// <summary>Adds the source's bookmarks that reach the pages in <paramref name="newIndex"/> (source index to target index) at the end of the target's top level, under <paramref name="mergeTitle"/> when set.</summary>
    public static void Bookmarks(PdfDocument source, PdfDocument target, Dictionary<int, int> newIndex, string? mergeTitle)
    {
        var outline = Outline.Read(target);
        var kept = Outline.Read(source).Items.Select(i => Keep(outline, i, newIndex)).OfType<OutlineItem>().ToList();
        if (kept.Count == 0) return;
        var parent = mergeTitle is null ? null : outline.Add(new OutlineItem { Title = mergeTitle, IsOpen = true });
        foreach (var item in kept) outline.Add(item, parent);
        outline.Write(target);
    }

    // An item stays when it points at a page taken or when something under it does; it then goes to the page's new place.
    private static OutlineItem? Keep(Outline outline, OutlineItem item, Dictionary<int, int> newIndex)
    {
        var children = item.Children.Select(c => Keep(outline, c, newIndex)).OfType<OutlineItem>().ToList();
        var destination = item.Destination is { } d && newIndex.TryGetValue(d.PageIndex, out int at) ? d with { PageIndex = at, Name = null } : null;
        if (destination is null && children.Count == 0) return null;
        var copy = new OutlineItem { Title = item.Title, Color = item.Color, Bold = item.Bold, Italic = item.Italic, IsOpen = item.IsOpen, Destination = destination };
        foreach (var child in children) outline.Add(child, copy);
        return copy;
    }

    private static void Labels(PdfDocument source, PdfDocument target, IReadOnlyList<int> sourcePages)
    {
        var ranges = PdfPageLabels.Read(source);
        if (ranges.Count == 0) return;
        var carried = new List<PageLabelRange>();
        PageLabelRange? last = null;
        for (int i = 0; i < sourcePages.Count; i++)
        {
            int page = sourcePages[i];
            var range = ranges.Where(r => r.StartPage <= page).MaxBy(r => r.StartPage) ?? new PageLabelRange(0);
            // A range that has a gap in the pages taken goes on counting where the source does.
            if (range != last || page != sourcePages[i - 1] + 1) carried.Add(range with { StartPage = i, FirstNumber = range.FirstNumber + page - range.StartPage });
            last = range;
        }
        PdfPageLabels.Write(target, carried);
    }

    private static void NamedDestinations(PdfDocument source, PdfDocument target, Dictionary<int, int> newIndex)
    {
        var found = PdfDestinations.Named(source).Where(n => newIndex.ContainsKey(n.Value.PageIndex)).ToList();
        if (found.Count == 0) return;
        var names = PdfNames.Ensure(target);
        var tree = target.Dict(names, "Dests");
        var entries = PdfNameTree.Read(target, tree).ToList();
        var taken = entries.Select(e => e.Key).ToHashSet();
        foreach (var (name, destination) in found)
        {
            // Two sources of a merge may use the same name; the first keeps it.
            if (taken.Contains(name) || PdfDestinations.ToObject(target, destination with { PageIndex = newIndex[destination.PageIndex], Name = null }) is not { } value) continue;
            entries.Add(new(name, value));
        }
        var root = PdfNameTree.Write(target, tree, entries);
        if (tree is null) names["Dests"] = target.Add(root);
    }
}
