using System.Text;

namespace LazyPDF.Core;

/// <summary>A document to merge and the pages of it to take (0-based, in the order given); null takes them all.</summary>
public sealed record MergeSource(PdfDocument Document, IReadOnlyList<int>? Pages = null);

/// <summary>
/// New documents made of pages of others. A new document holds the pages asked for and what they
/// use and nothing else: no tree, outlines, names or tags of the source, no resource a page only
/// lists. Page labels, bookmarks and article threads are not carried over.
/// </summary>
public static class PageAssembly
{
    /// <summary>A document of the pages at these indexes, in this order. Keeps the source's /Info. Throws <see cref="OperationCanceledException"/> when <paramref name="cancel"/> is raised.</summary>
    public static PdfDocument Extract(PdfDocument source, IReadOnlyList<int> pages, CancellationToken cancel = default)
    {
        if (pages.Count == 0) throw new ArgumentException("There are no pages to take.", nameof(pages));
        var target = Blank(source.Version);
        var importer = new PageImporter(source, target);
        var copies = importer.Import(pages, cancel);
        if (source.Trailer["Info"] is { } info && source.Info is not null) target.Trailer["Info"] = importer.CopyValue(info);
        PageTree.Set(target, copies);
        return target;
    }

    /// <summary>The pages of each source one after the other. A document listed twice is copied once. <paramref name="cancel"/> is checked between documents and between pages.</summary>
    public static PdfDocument Merge(IReadOnlyList<MergeSource> sources, CancellationToken cancel = default)
    {
        if (sources.Count == 0) throw new ArgumentException("There is nothing to merge.", nameof(sources));
        var target = Blank(sources.Select(s => s.Document.Version).MaxBy(v => Version.TryParse(v, out var parsed) ? parsed : new Version(1, 0))!);
        var importers = new Dictionary<PdfDocument, PageImporter>(ReferenceEqualityComparer.Instance);
        var order = new List<PdfReference>();
        var origins = new List<object>();
        foreach (var (document, pages) in sources)
        {
            cancel.ThrowIfCancellationRequested();
            if (!importers.TryGetValue(document, out var importer)) importers[document] = importer = new PageImporter(document, target);
            var copies = importer.Import(pages ?? [.. Enumerable.Range(0, document.Pages.Count)], cancel);
            order.AddRange(copies);
            origins.AddRange(copies.Select(_ => (object)document));
        }
        if (order.Count == 0) throw new ArgumentException("The sources have no pages.", nameof(sources));
        var first = sources[0].Document;
        if (first.Trailer["Info"] is { } info && first.Info is not null) target.Trailer["Info"] = importers[first].CopyValue(info);
        PageTree.Set(target, order);
        StampRuns.Separate(target, [.. target.Pages.Select((p, i) => (p, origins[i]))]);
        return target;
    }

    /// <summary>Parts of <paramref name="count"/> pages each; the last holds what is left.</summary>
    public static IReadOnlyList<PdfDocument> SplitEvery(PdfDocument source, int count, CancellationToken cancel = default)
    {
        if (count < 1) throw new ArgumentOutOfRangeException(nameof(count));
        int total = source.Pages.Count;
        return SplitByRanges(source, [.. Enumerable.Range(0, total == 0 ? 0 : (total - 1) / count + 1).Select(p => (IReadOnlyList<int>)[.. Enumerable.Range(p * count, Math.Min(count, total - p * count))])], cancel);
    }

    /// <summary>One part for each list of pages.</summary>
    public static IReadOnlyList<PdfDocument> SplitByRanges(PdfDocument source, IReadOnlyList<IReadOnlyList<int>> parts, CancellationToken cancel = default) =>
        [.. parts.Select(p => Extract(source, p, cancel))];

    /// <summary>A new part starts at each of these pages (0-based); the first part starts at page 0. Where bookmarks of the top level point is a good list.</summary>
    public static IReadOnlyList<PdfDocument> SplitAt(PdfDocument source, IEnumerable<int> starts, CancellationToken cancel = default)
    {
        int total = source.Pages.Count;
        var cuts = starts.Where(s => s != 0).Distinct().Order().ToList();
        if (cuts.Any(c => c < 0 || c >= total)) throw new ArgumentOutOfRangeException(nameof(starts));
        cuts.Insert(0, 0);
        cuts.Add(total);
        return SplitByRanges(source, [.. Enumerable.Range(0, cuts.Count - 1).Select(i => (IReadOnlyList<int>)[.. Enumerable.Range(cuts[i], cuts[i + 1] - cuts[i])])], cancel);
    }

    /// <summary>
    /// Parts that each save (<see cref="PdfDocument.SaveRewrite"/> with <paramref name="options"/>) to
    /// no more than <paramref name="maxBytes"/>, as many pages as fit. A page that is bigger alone
    /// is a part of its own. The size of a part is measured by saving it, so the work is a few saves of each part; <paramref name="cancel"/> is checked before each.
    /// </summary>
    public static IReadOnlyList<PdfDocument> SplitBySize(PdfDocument source, long maxBytes, PdfSaveOptions? options = null, CancellationToken cancel = default)
    {
        if (maxBytes < 1) throw new ArgumentOutOfRangeException(nameof(maxBytes));
        int total = source.Pages.Count;
        bool Fits(int start, int length) =>
            Extract(source, [.. Enumerable.Range(start, length)], cancel).SaveRewrite(options).Length <= maxBytes;

        var parts = new List<IReadOnlyList<int>>();
        for (int at = 0; at < total;)
        {
            int low = 1, high = total - at;
            for (int probe = 2; probe <= total - at; probe *= 2)
            {
                if (Fits(at, probe)) { low = probe; continue; }
                high = probe - 1;
                break;
            }
            while (low < high)
            {
                int mid = (low + high + 1) / 2;
                if (Fits(at, mid)) low = mid;
                else high = mid - 1;
            }
            parts.Add([.. Enumerable.Range(at, low)]);
            at += low;
        }
        return SplitByRanges(source, parts, cancel);
    }

    // A file of a catalog and an empty tree, with a proper table so that opening it needs no repair.
    private static PdfDocument Blank(string version)
    {
        string head = $"%PDF-{version}\n%âãÏÓ\n";
        const string catalog = "1 0 obj\n<</Type /Catalog /Pages 2 0 R>>\nendobj\n";
        const string tree = "2 0 obj\n<</Type /Pages /Kids [] /Count 0>>\nendobj\n";
        int first = head.Length, second = first + catalog.Length, table = second + tree.Length;
        string end = $"xref\n0 3\n0000000000 65535 f \n{first:D10} 00000 n \n{second:D10} 00000 n \ntrailer\n<</Size 3 /Root 1 0 R>>\nstartxref\n{table}\n%%EOF\n";
        return PdfDocument.Open(Encoding.Latin1.GetBytes(head + catalog + tree + end));
    }
}
