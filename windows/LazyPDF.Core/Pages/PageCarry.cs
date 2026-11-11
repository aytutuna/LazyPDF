namespace LazyPDF.Core;

// What a new document keeps of the source besides the pages: the bookmarks, labels, named
// destinations and attached files of the pages taken, and the language and XMP of the document.
// Runs once the pages are in the target's tree, since destinations are written by page index.
internal static class PageCarry
{
    /// <summary>
    /// Carries what belongs to the source pages at <paramref name="sourcePages"/>, which are the target's pages from
    /// <paramref name="firstNewIndex"/> on. <paramref name="mergeTitle"/> is set for one source of a merge: its bookmarks go under an item with that title and no labels are written.
    /// </summary>
    public static void Carry(PdfDocument source, PdfDocument target, IReadOnlyList<int> sourcePages, int firstNewIndex, string? mergeTitle = null)
    {
        var newIndex = new Dictionary<int, int>();
        for (int i = 0; i < sourcePages.Count; i++) newIndex.TryAdd(sourcePages[i], firstNewIndex + i);
        Bookmarks(source, target, newIndex, mergeTitle);
        if (mergeTitle is null) Labels(source, target, sourcePages);
        NamedDestinations(source, target, newIndex);
        foreach (var file in PdfAttachments.List(source).Where(a => a.PageIndex is null))
        {
            PdfAttachments.Add(target, file.FileName, PdfAttachments.Extract(source, file), file.MimeType, file.Description, file.Created, file.Modified);
        }
    }

    /// <summary>The source's /Lang, and its XMP when the target has the /Info as well.</summary>
    public static void Catalog(PdfDocument source, PdfDocument target, PageImporter importer)
    {
        if (source.Catalog["Lang"] is { } lang) target.Catalog["Lang"] = importer.CopyValue(lang);
        if (target.Trailer["Info"] is not null && source.Catalog["Metadata"] is { } xmp) target.Catalog["Metadata"] = importer.CopyValue(xmp);
    }

    private static void Bookmarks(PdfDocument source, PdfDocument target, Dictionary<int, int> newIndex, string? mergeTitle)
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
