using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>Says which pages a pattern ran out of time on, for the find bar, the Search panel and the Redact tool.</summary>
public static class TimedOutText
{
    private const int Listed = 5;

    /// <summary>Takes 0-based page indexes, ascending; null when there are none.</summary>
    public static string? For(IReadOnlyList<int> pages)
    {
        if (pages.Count == 0) return null;
        if (pages.Count == 1) return Loc.T("The pattern took too long on page {0}; it was not searched.", pages[0] + 1);
        if (pages.Count > Listed)
            return Loc.T("The pattern took too long on {0} pages, the first being page {1}; they were not searched.", pages.Count, pages[0] + 1);
        string list = Loc.T("{0} and {1}", string.Join(", ", pages.Take(pages.Count - 1).Select(p => p + 1)), pages[^1] + 1);
        return Loc.T("The pattern took too long on pages {0}; they were not searched.", list);
    }
}
