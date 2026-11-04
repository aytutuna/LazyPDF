using System.Text;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Stamps;

public enum PageSet
{
    All,
    Odd,
    Even,
    Typed,
}

/// <summary>Which pages a stamp goes on, as the form states it, and the way back from a run's pages to the form.</summary>
public static class PageChoice
{
    /// <summary>The 0-based pages, null for every page, or what is wrong with the typed range.</summary>
    public static (IReadOnlyList<int>? Pages, string? Error) Resolve(PageSet set, string typed, int count)
    {
        switch (set)
        {
            case PageSet.All:
                return (null, null);
            case PageSet.Odd:
                return ([.. Enumerable.Range(0, count).Where(i => i % 2 == 0)], null);
            case PageSet.Even:
                return ([.. Enumerable.Range(0, count).Where(i => i % 2 == 1)], null);
            default:
                var parsed = PageRange.Parse(typed, count);
                return parsed.IsSuccess ? (parsed.Pages, null) : ([], parsed.Error!.Message);
        }
    }

    /// <summary>The pages a stamp lands on, in order, as Core takes them.</summary>
    public static IReadOnlyList<int> Targets(IReadOnlyList<int>? pages, int count) =>
        pages is null ? [.. Enumerable.Range(0, count)] : [.. pages.Where(i => i >= 0 && i < count).Distinct().Order()];

    /// <summary>"1-3, 5" for 0-based pages 0, 1, 2, 4.</summary>
    public static string Describe(IReadOnlyList<int> pages)
    {
        var text = new StringBuilder();
        var sorted = pages.Distinct().Order().ToList();
        for (int i = 0; i < sorted.Count;)
        {
            int end = i;
            while (end + 1 < sorted.Count && sorted[end + 1] == sorted[end] + 1) end++;
            if (text.Length > 0) text.Append(", ");
            text.Append(sorted[i] + 1);
            if (end > i) text.Append('-').Append(sorted[end] + 1);
            i = end + 1;
        }
        return text.ToString();
    }
}
