using LazyPDF.Core;

namespace LazyPDF.App.Tools.Standards;

/// <summary>One rule the file breaks, with every place it breaks it in; the places that are pages can be visited in turn.</summary>
public sealed class IssueRow
{
    private readonly int[] _pages;
    private readonly PdfAIssue _first;
    private readonly int _count;
    private readonly string? _clause;
    private int _next;

    private IssueRow(PdfAIssue first, int count, int[] pages, string? clause)
    {
        _first = first;
        _count = count;
        _pages = pages;
        _clause = clause;
    }

    public string Message => _first.Message;

    public string Clause => _clause ?? Loc.T("ISO 19005 clause {0}", _first.Clause);

    /// <summary>The first place, and how many more there are.</summary>
    public string Where => _count > 1 ? Loc.T("{0}, and {1} more", _first.Where, _count - 1) : _first.Where;

    public string Summary => Message + ". " + Where + ". " + Clause;

    public bool HasPlaces => _pages.Length > 0;

    public string PlaceText => _pages.Length == 0 ? "" : Loc.T("Go to page {0}", _pages[_next % _pages.Length] + 1);

    public int NextPage()
    {
        int page = _pages[_next % _pages.Length];
        _next++;
        return page;
    }

    /// <summary>The issues with the same rule and sentence made into one row each, in the order they were found.</summary>
    public static IReadOnlyList<IssueRow> Group(IEnumerable<PdfAIssue> issues) => Group(issues.Select(i => (i, (string?)null)));

    /// <summary>The same for the PDF/UA check, whose rows name the Matterhorn condition and the clause of ISO 14289-1.</summary>
    public static IReadOnlyList<IssueRow> Group(IEnumerable<PdfUaIssue> issues) =>
        Group(issues.Select(i => (new PdfAIssue(i.Condition, i.Where, i.Message), (string?)(i.Condition.Length == 0 ? Loc.T("ISO 14289-1 clause {0}", i.Clause) : Loc.T("Matterhorn {0}, ISO 14289-1 clause {1}", i.Condition, i.Clause)))));

    private static IReadOnlyList<IssueRow> Group(IEnumerable<(PdfAIssue Issue, string? Clause)> issues)
    {
        string prefix = PdfAText.PageName(0)[..^1];
        return issues
            .GroupBy(i => (i.Issue.Clause, i.Issue.Message))
            .Select(g => new IssueRow(g.First().Issue, g.Count(), g.Select(i => PageOf(i.Issue.Where, prefix)).Where(p => p >= 0).Distinct().Order().ToArray(), g.First().Clause))
            .ToList();
    }

    // "Page 3" and "Page 3, annotation 2" are the places that name a page; the word comes from the same text the validator used.
    private static int PageOf(string where, string prefix)
    {
        if (!where.StartsWith(prefix, StringComparison.Ordinal)) return -1;
        int end = prefix.Length;
        while (end < where.Length && char.IsAsciiDigit(where[end])) end++;
        return int.TryParse(where.AsSpan(prefix.Length, end - prefix.Length), out int page) && page > 0 ? page - 1 : -1;
    }
}
