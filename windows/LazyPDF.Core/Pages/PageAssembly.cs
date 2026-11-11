using System.Text;

namespace LazyPDF.Core;

/// <summary>A document to merge and the pages of it to take (0-based, in the order given); null takes them all.</summary>
public sealed record MergeSource(PdfDocument Document, IReadOnlyList<int>? Pages = null);

/// <summary>
/// New documents made of pages of others. A new document holds the pages asked for and what they
/// use and nothing else: no tree, names or tags of the source, no resource a page only lists. Of
/// the rest of the source it carries what belongs to those pages (see <see cref="PageCarry"/>);
/// article threads are not carried over.
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
        PageCarry.Catalog(source, target, importer);
        PageTree.Set(target, copies);
        PageCarry.Carry(source, target, pages, 0);
        return target;
    }

    /// <summary>The pages of each source one after the other. A document listed twice is copied once. <paramref name="cancel"/> is checked between documents and between pages. Each source with bookmarks adds one under the title in its /Info, else the one in <paramref name="titles"/> at its place.</summary>
    public static PdfDocument Merge(IReadOnlyList<MergeSource> sources, CancellationToken cancel = default, IReadOnlyList<string>? titles = null)
    {
        if (sources.Count == 0) throw new ArgumentException("There is nothing to merge.", nameof(sources));
        var target = Blank(sources.Select(s => s.Document.Version).MaxBy(v => Version.TryParse(v, out var parsed) ? parsed : new Version(1, 0))!);
        var importers = new Dictionary<PdfDocument, PageImporter>(ReferenceEqualityComparer.Instance);
        var order = new List<PdfReference>();
        var origins = new List<object>();
        var taken = new List<(IReadOnlyList<int> Pages, int Start)>();
        foreach (var (document, pages) in sources)
        {
            cancel.ThrowIfCancellationRequested();
            if (!importers.TryGetValue(document, out var importer)) importers[document] = importer = new PageImporter(document, target);
            var indexes = pages ?? [.. Enumerable.Range(0, document.Pages.Count)];
            var copies = importer.Import(indexes, cancel);
            taken.Add((indexes, order.Count));
            order.AddRange(copies);
            origins.AddRange(copies.Select(_ => (object)document));
        }
        if (order.Count == 0) throw new ArgumentException("The sources have no pages.", nameof(sources));
        var first = sources[0].Document;
        if (first.Trailer["Info"] is { } info && first.Info is not null) target.Trailer["Info"] = importers[first].CopyValue(info);
        PageCarry.Catalog(first, target, importers[first]);
        PageTree.Set(target, order);
        for (int i = 0; i < sources.Count; i++)
        {
            var document = sources[i].Document;
            string? title = document.Info is { } own ? PdfText.Read(document, own, "Title") : null;
            PageCarry.Carry(document, target, taken[i].Pages, taken[i].Start, string.IsNullOrEmpty(title) ? titles?.ElementAtOrDefault(i) ?? "" : title);
        }
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
    /// is a part of its own. The size of a part is measured by saving it, starting from an estimate
    /// out of the size of the source, so the work is a few saves of each part; the document that fit is the part.
    /// <paramref name="cancel"/> is checked before each save.
    /// </summary>
    public static IReadOnlyList<PdfDocument> SplitBySize(PdfDocument source, long maxBytes, PdfSaveOptions? options = null, CancellationToken cancel = default)
    {
        if (maxBytes < 1) throw new ArgumentOutOfRangeException(nameof(maxBytes));
        int total = source.Pages.Count;
        var fitted = new Dictionary<(int Start, int Length), PdfDocument>();
        bool Fits(int start, int length)
        {
            var candidate = Extract(source, [.. Enumerable.Range(start, length)], cancel);
            if (candidate.SaveRewrite(options, cancel: cancel).Length > maxBytes) return false;
            fitted[(start, length)] = candidate;
            return true;
        }

        var parts = new List<PdfDocument>();
        for (int at = 0; at < total;)
        {
            fitted.Clear();
            int remaining = total - at;
            int low = 1, high = remaining + 1;
            if (remaining > 1)
            {
                int guess = (int)Math.Clamp((double)maxBytes * total / Math.Max(source.Length, 1), 2, remaining);
                if (Fits(at, guess))
                {
                    low = guess;
                    for (int step = 1; low + step < high; step *= 2)
                    {
                        if (Fits(at, low + step)) low += step;
                        else { high = low + step; break; }
                    }
                }
                else
                {
                    high = guess;
                    for (int step = 1; high - step > low; step *= 2)
                    {
                        if (Fits(at, high - step)) { low = high - step; break; }
                        high -= step;
                    }
                }
                while (low + 1 < high)
                {
                    int mid = (low + high) / 2;
                    if (Fits(at, mid)) low = mid;
                    else high = mid;
                }
            }
            parts.Add(fitted.TryGetValue((at, low), out var part) ? part : Extract(source, [.. Enumerable.Range(at, low)], cancel));
            at += low;
        }
        return parts;
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
