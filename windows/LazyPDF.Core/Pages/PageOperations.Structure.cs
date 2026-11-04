namespace LazyPDF.Core;

public static partial class PageOperations
{
    /// <summary>
    /// Removes pages and what pointed at them: bookmarks and links keep their place but lose the
    /// destination, named destinations and form fields on the pages go, page labels are renumbered.
    /// A tagged document loses its structure tree when a removed page was tagged (the tree names
    /// pages and marked content by number, and is not edited). Refuses to remove every page.
    /// </summary>
    public static void Delete(PdfDocument document, IEnumerable<int> pages)
    {
        var doomed = Select(document, pages);
        if (doomed.Count == 0) return;
        var all = document.Pages;
        if (doomed.Count == all.Count) throw new ArgumentException("A document keeps at least one page.", nameof(pages));

        PageCleanup.BeforeDelete(document, doomed);
        var gone = doomed.Select(p => p.Reference.Number).ToHashSet();
        PageTree.Set(document, [.. all.Where(p => !gone.Contains(p.Reference.Number)).Select(p => p.Reference)]);
        foreach (int number in gone) document.Delete(number);
    }

    /// <summary>The page at <c>order[i]</c> becomes page <c>i</c>. <paramref name="order"/> must name every page once.</summary>
    public static void Reorder(PdfDocument document, IReadOnlyList<int> order)
    {
        var pages = document.Pages;
        if (order.Count != pages.Count || order.Distinct().Count() != order.Count || order.Any(i => (uint)i >= (uint)pages.Count))
        {
            throw new ArgumentException("The order must name each page once.", nameof(order));
        }
        if (order.Select((page, i) => page == i).All(same => same)) return;
        PageTree.Set(document, [.. order.Select(i => pages[i].Reference)]);
    }

    /// <summary>Moves the pages, in their own order, to stand before the page that is now at <paramref name="before"/> (the page count puts them last).</summary>
    public static void Move(PdfDocument document, IEnumerable<int> pages, int before)
    {
        int count = document.Pages.Count;
        if (before < 0 || before > count) throw new ArgumentOutOfRangeException(nameof(before));
        var moved = Select(document, pages).Select(p => p.Index).ToList();
        var rest = Enumerable.Range(0, count).Except(moved).ToList();
        int at = rest.Count(i => i < before);
        Reorder(document, [.. rest.Take(at), .. moved, .. rest.Skip(at)]);
    }

    /// <summary>Puts a copy of each page right after it. Content, fonts and images are shared with the original; annotations and form fields are copied, and a copied field is renamed ("name_2").</summary>
    public static void Duplicate(PdfDocument document, IEnumerable<int> pages)
    {
        var chosen = Select(document, pages);
        if (chosen.Count == 0) return;
        var copies = new PageImporter(document, document).Import([.. chosen.Select(p => p.Index)]);
        var after = chosen.Select((p, i) => (p.Index, Copy: copies[i])).ToDictionary(c => c.Index, c => c.Copy);
        var order = new List<PdfReference>();
        foreach (var page in document.Pages)
        {
            order.Add(page.Reference);
            if (after.TryGetValue(page.Index, out var copy)) order.Add(copy);
        }
        foreach (int index in chosen.Select(p => p.Index).Reverse()) PageLabels.Inserted(document, index + 1, 1);
        PageTree.Set(document, order);
    }

    /// <summary>Inserts <paramref name="count"/> empty pages of the given size in points so that the first is page <paramref name="at"/>.</summary>
    public static void InsertBlank(PdfDocument document, int at, double width, double height, int count = 1)
    {
        if (at < 0 || at > document.Pages.Count) throw new ArgumentOutOfRangeException(nameof(at));
        if (count < 1) throw new ArgumentOutOfRangeException(nameof(count));
        if (!(width is > 0 and <= MaxPageSize) || !(height is > 0 and <= MaxPageSize)) throw new ArgumentOutOfRangeException(nameof(width), "The size is out of range.");
        var blank = Enumerable.Range(0, count).Select(_ =>
        {
            var page = new PdfDictionary();
            var box = new PdfRect(0, 0, width, height);
            page["Type"] = new PdfName("Page");
            page["MediaBox"] = box.ToArray();
            page["CropBox"] = box.ToArray();
            page["Rotate"] = new PdfNumber(0L);
            page["Resources"] = new PdfDictionary();
            return document.Add(page);
        }).ToList();
        InsertAt(document, at, blank);
    }

    /// <summary>
    /// Copies pages of <paramref name="source"/> into <paramref name="target"/> so that the first is
    /// page <paramref name="at"/>. Everything a page needs is copied once per call, however many
    /// pages share it; the source's tree, tags, bookmarks and article threads stay behind. Links to
    /// pages that did not come across are dropped; form fields join the target's /AcroForm and are
    /// renamed on a clash. The source may be the target.
    /// </summary>
    public static void ImportPages(PdfDocument target, PdfDocument source, IReadOnlyList<int> sourcePages, int at)
    {
        if (at < 0 || at > target.Pages.Count) throw new ArgumentOutOfRangeException(nameof(at));
        if (sourcePages.Count == 0) return;
        InsertAt(target, at, new PageImporter(source, target).Import(sourcePages));
        if (!ReferenceEquals(source, target))
        {
            StampRuns.Separate(target, [.. target.Pages.Select((p, i) => (p, i >= at && i < at + sourcePages.Count ? (object)source : target))]);
        }
    }

    private static void InsertAt(PdfDocument document, int at, List<PdfReference> added)
    {
        var order = document.Pages.Select(p => p.Reference).ToList();
        order.InsertRange(at, added);
        PageLabels.Inserted(document, at, added.Count);
        PageTree.Set(document, order);
    }
}
