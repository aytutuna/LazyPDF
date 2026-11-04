namespace LazyPDF.Core;

// Page labels follow the pages: a range runs from its first page to the next range's, so removing
// or inserting pages moves the starts.
internal static class PageLabels
{
    /// <summary>Renumbers after pages were removed (indexes as they were). A range with no page left is dropped; one that lost its first pages starts its numbering further on.</summary>
    public static void Removed(PdfDocument document, IReadOnlyCollection<int> removed, int pageCount)
    {
        var ranges = PdfPageLabels.Read(document);
        if (ranges.Count == 0) return;
        var gone = removed.ToHashSet();
        var result = new List<PageLabelRange>();
        for (int i = 0; i < ranges.Count; i++)
        {
            int start = ranges[i].StartPage, end = i + 1 < ranges.Count ? ranges[i + 1].StartPage : pageCount;
            int leading = 0;
            while (start + leading < end && gone.Contains(start + leading)) leading++;
            if (start + leading >= end) continue;
            result.Add(ranges[i] with { StartPage = start - gone.Count(g => g < start), FirstNumber = ranges[i].FirstNumber + leading });
        }
        PdfPageLabels.Write(document, result);
    }

    /// <summary>Makes room for <paramref name="count"/> pages inserted at <paramref name="at"/>; they continue the range before.</summary>
    public static void Inserted(PdfDocument document, int at, int count)
    {
        var ranges = PdfPageLabels.Read(document);
        if (ranges.Count == 0) return;
        PdfPageLabels.Write(document, ranges.Select(r => r.StartPage >= at ? r with { StartPage = r.StartPage + count } : r));
    }
}
