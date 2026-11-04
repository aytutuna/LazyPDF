namespace LazyPDF.Core;

// The page tree (ISO 32000-1 7.7.3), walked from the catalog without trusting it: /Count, /Type and
// /Parent are not needed, a loop or junk in /Kids costs only the entries it spoils.
public sealed partial class PdfDocument
{
    private const int MaxTreeDepth = 256;

    private static readonly string[] PageEvidence = ["Contents", "MediaBox", "Resources", "Parent"];

    private List<PdfPage>? _pages;
    private bool _pagesWalked;

    /// <summary>The pages in reading order. Built on first use and kept; call <see cref="RefreshPages"/> after changing the tree.</summary>
    public IReadOnlyList<PdfPage> Pages => _pages ??= WalkPages();

    /// <summary>Forgets the page list so that the next use walks the tree again.</summary>
    internal void RefreshPages() => _pages = null;

    private List<PdfPage> WalkPages()
    {
        bool first = !_pagesWalked;
        _pagesWalked = true;
        var pages = new List<PdfPage>();
        var visited = new HashSet<int>();
        int skipped = 0;
        if (Catalog["Pages"] is { } root) Walk(root, default, 0);

        if (first)
        {
            if (skipped > 0) AddRepair($"The page tree has {skipped} entries that are not pages or that loop back; they were left out.");
            if (Integer(Dict(Catalog, "Pages"), "Count") is { } declared && declared != pages.Count && pages.Count > 0)
            {
                AddRepair($"The page tree says {declared} pages and has {pages.Count}.");
            }
            if (pages.Count == 0) FindPagesByScan(pages);
        }
        return pages;

        void Walk(PdfObject node, PageInheritance inherited, int depth)
        {
            var reference = node as PdfReference;
            if (depth > MaxTreeDepth || (reference is not null && !visited.Add(reference.Number)) || Resolve(node) is not PdfDictionary dictionary)
            {
                skipped++;
                return;
            }
            string? type = Name(dictionary, "Type");
            inherited = new PageInheritance(
                Own(dictionary, "Resources") ?? inherited.Resources, Own(dictionary, "MediaBox") ?? inherited.MediaBox,
                Own(dictionary, "CropBox") ?? inherited.CropBox, Own(dictionary, "Rotate") ?? inherited.Rotate);
            if (type != "Page" && Array(dictionary, "Kids") is { } kids)
            {
                foreach (var kid in kids.Items) Walk(kid, inherited, depth + 1);
                return;
            }
            if (type == "Pages") return;
            // A page without a type is told by what pages have; a direct one cannot be referred to.
            bool looksLikePage = type == "Page" || PageEvidence.Any(dictionary.ContainsKey);
            if (reference is null || !looksLikePage || type is not (null or "Page"))
            {
                skipped++;
                return;
            }
            pages.Add(new PdfPage(this, dictionary, reference, pages.Count, inherited));
        }
    }

    private PdfObject? Own(PdfDictionary dictionary, string key) => dictionary[key] is { } value and not PdfNull ? value : null;

    /// <summary>A tree with no pages in it, in a file that has page objects: they are used in the order they are in the file.</summary>
    private void FindPagesByScan(List<PdfPage> pages)
    {
        foreach (int number in EnsureScan().Pages)
        {
            var reference = new PdfReference(number, GenerationOf(number));
            if (Get(number) is PdfDictionary dictionary && Name(dictionary, "Type") == "Page")
            {
                pages.Add(new PdfPage(this, dictionary, reference, pages.Count, default));
            }
        }
        if (pages.Count > 0) AddRepair($"The page tree holds no pages; used the {pages.Count} page objects found by scanning.");
    }
}
