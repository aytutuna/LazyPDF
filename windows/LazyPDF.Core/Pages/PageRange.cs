namespace LazyPDF.Core;

// From Lazy Print's PageRange.cs: the pages a user types ("1-3, 5, 8-"), the same in all three apps.

/// <summary>What is wrong with the typed pages, in words for the user.</summary>
public sealed record PageRangeError(string Message);

/// <summary>The pages typed (0-based, in the order typed, repeats kept), or what is wrong with them.</summary>
public sealed record PageRangeResult(IReadOnlyList<int> Pages, PageRangeError? Error)
{
    public bool IsSuccess => Error is null;

    public bool Equals(PageRangeResult? other) =>
        other is not null && Error == other.Error && Pages.SequenceEqual(other.Pages);

    public override int GetHashCode() => HashCode.Combine(Pages.Count, Error);
}

public static class PageRange
{
    /// <summary>
    /// Parses "1-3, 5, 8-": single pages, ranges and an open range to the last page, separated by commas,
    /// counted from 1. A page past <paramref name="pageCount"/> is an error ("Page 9 is past the end (8 pages)").
    /// </summary>
    public static PageRangeResult Parse(string text, int pageCount)
    {
        var pages = new List<int>();
        foreach (string item in text.Split(','))
        {
            string part = item.Trim();
            int dash = part.IndexOf('-');
            int first, last;
            if (dash < 0)
            {
                if (!TryNumber(part, out first)) return Fail(PagesText.RangeUsage);
                last = first;
            }
            else
            {
                string end = part[(dash + 1)..].Trim();
                if (!TryNumber(part[..dash].Trim(), out first)) return Fail(PagesText.RangeUsage);
                if (end.Length == 0) last = Math.Max(first, pageCount);
                else if (!TryNumber(end, out last) || last < first) return Fail(PagesText.RangeUsage);
            }
            if (last > pageCount)
            {
                int past = first > pageCount ? first : last;
                return Fail(PagesText.PastTheEnd(past, pageCount));
            }
            for (int page = first; page <= last; page++) pages.Add(page - 1);
        }
        return new PageRangeResult(pages, null);
    }

    private static PageRangeResult Fail(string message) => new([], new PageRangeError(message));

    private static bool TryNumber(string text, out int number)
    {
        number = 0;
        return text.Length > 0 && text.All(c => c is >= '0' and <= '9') && int.TryParse(text, out number) && number >= 1;
    }
}
