namespace LazyPDF.Core;

// Which elements of the source's tag tree have nothing left on the pages taken, found without copying
// anything, so that a part never copies the tree of the pages it leaves out. Follows
// RedactionStructure.Prune, with the pages left out as the ones whose content is removed.
internal static class TagCut
{
    private const int MaxDepth = 64;

    /// <summary>The object numbers of the elements to leave out, given the numbers of the pages taken and of all the source's pages.</summary>
    public static HashSet<int> Dead(PdfDocument source, PdfObject root, HashSet<int> taken, HashSet<int> pages)
    {
        var dead = new HashSet<int>();
        if (source.Resolve(root) is PdfDictionary top)
        {
            Alive(source, top, null, taken, pages, dead, new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance), 0);
        }
        return dead;
    }

    private static bool Alive(PdfDocument source, PdfDictionary element, int? page, HashSet<int> taken, HashSet<int> pages, HashSet<int> dead, HashSet<PdfDictionary> seen, int depth)
    {
        if (depth > MaxDepth || !seen.Add(element)) return true;
        page = PageOf(element, page, pages);
        bool Shown(int? at) => at is not { } number || taken.Contains(number);
        List<PdfObject> kids = source.Resolve(element["K"]) is PdfArray array ? array.Items : element["K"] is { } single ? [single] : [];
        int kept = 0;
        foreach (var kid in kids)
        {
            switch (source.Resolve(kid))
            {
                case PdfNumber:
                    if (Shown(page)) kept++;
                    break;
                case PdfDictionary d when RedactionStructure.IsContentItem(source, d, "MCR", "MCID"):
                    if (d.ContainsKey("Stm") || Shown(PageOf(d, page, pages))) kept++;
                    break;
                case PdfDictionary d when RedactionStructure.IsContentItem(source, d, "OBJR", "Obj"):
                    if (source.Resolve(d["Obj"]) is not null && Shown(PageOf(d, page, pages))) kept++;
                    break;
                case PdfDictionary child:
                    if (Alive(source, child, page, taken, pages, dead, seen, depth + 1)) kept++;
                    else if (kid is PdfReference reference) dead.Add(reference.Number);
                    break;
            }
        }
        return kept > 0 || kids.Count == 0;
    }

    private static int? PageOf(PdfDictionary item, int? inherited, HashSet<int> pages) =>
        item["Pg"] is PdfReference own && pages.Contains(own.Number) ? own.Number : inherited;
}
