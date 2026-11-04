namespace LazyPDF.Core;

// /PageLabels (ISO 32000-1 12.4.2) as the number tree it is, read flat and written flat when pages
// come or go. Ranges are by position: a range runs from its first page to the next range's.
internal static class PageLabels
{
    private const int MaxNodes = 100_000;

    private sealed record Range(int Start, PdfObject Label);

    /// <summary>Renumbers after pages were removed (indexes as they were). A range with no page left is dropped; one that lost its first pages starts its numbering further on.</summary>
    public static void Removed(PdfDocument document, IReadOnlyCollection<int> removed, int pageCount)
    {
        if (!Read(document, out var root, out var ranges)) return;
        var gone = removed.ToHashSet();
        var result = new List<Range>();
        for (int i = 0; i < ranges.Count; i++)
        {
            int start = ranges[i].Start, end = i + 1 < ranges.Count ? ranges[i + 1].Start : pageCount;
            int leading = 0;
            while (start + leading < end && gone.Contains(start + leading)) leading++;
            if (start + leading >= end) continue;
            var label = ranges[i].Label;
            if (leading > 0 && document.Resolve(label) is PdfDictionary dictionary)
            {
                var moved = dictionary.Copy();
                moved["St"] = new PdfNumber((document.Integer(dictionary, "St") ?? 1) + leading);
                label = moved;
            }
            result.Add(new Range(start - gone.Count(g => g < start), label));
        }
        Write(root, result);
    }

    /// <summary>Makes room for <paramref name="count"/> pages inserted at <paramref name="at"/>; they continue the range before.</summary>
    public static void Inserted(PdfDocument document, int at, int count)
    {
        if (!Read(document, out var root, out var ranges)) return;
        var result = ranges.Select(r => r.Start >= at ? r with { Start = r.Start + count } : r).ToList();
        if (result[0].Start > 0) result.Insert(0, new Range(0, new PdfDictionary { ["S"] = new PdfName("D") }));
        Write(root, result);
    }

    private static bool Read(PdfDocument document, out PdfDictionary root, out List<Range> ranges)
    {
        ranges = [];
        root = document.Dict(document.Catalog, "PageLabels")!;
        if (root is null) return false;
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var stack = new Stack<PdfDictionary>();
        stack.Push(root);
        while (stack.Count > 0 && seen.Count < MaxNodes)
        {
            var node = stack.Pop();
            if (!seen.Add(node)) continue;
            if (document.Array(node, "Nums") is { } nums)
            {
                for (int i = 0; i + 1 < nums.Items.Count; i += 2)
                {
                    if (document.Resolve(nums.Items[i]) is PdfNumber { Integer: >= 0 and <= int.MaxValue } key) ranges.Add(new Range((int)key.Integer!.Value, nums.Items[i + 1]));
                }
            }
            if (document.Array(node, "Kids") is { } kids)
            {
                foreach (var kid in kids.Items)
                {
                    if (document.Resolve(kid) is PdfDictionary child) stack.Push(child);
                }
            }
        }
        ranges = [.. ranges.OrderBy(r => r.Start)];
        return ranges.Count > 0;
    }

    private static void Write(PdfDictionary root, List<Range> ranges)
    {
        root.Remove("Kids");
        root.Remove("Limits");
        root["Nums"] = new PdfArray([.. ranges.SelectMany(r => new[] { new PdfNumber((long)r.Start), r.Label })]);
    }
}
