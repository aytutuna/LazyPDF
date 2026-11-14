using System.Text.RegularExpressions;

namespace LazyPDF.Core;

/// <summary>How a search reads its query.</summary>
/// <param name="MatchCase">Capitals must match; by default they do not matter (dotless i stays a different letter from i).</param>
/// <param name="WholeWord">The match may not touch a letter or digit on either side.</param>
/// <param name="Regex">The query is a regular expression over the text of the page, where a line break is one space.</param>
/// <param name="FoldDiacritics">Accents and marks do not matter, and I, dotted and dotless I and i are all the same letter.</param>
public sealed record TextSearchOptions(bool MatchCase = false, bool WholeWord = false, bool Regex = false, bool FoldDiacritics = false);

/// <summary>A hit: the page, its characters and the boxes to paint, one for each line it crosses.</summary>
public sealed record SearchMatch(int Page, TextRange Range, string Text, IReadOnlyList<TextQuad> Quads)
{
    /// <summary>Where the hit is in the text that was searched, for a replacement that has to cut a character's own text.</summary>
    internal HitCut? Source { get; init; }
}

/// <summary>A hit in the searched text: which text (0, or 1 with line-end hyphens dropped), where it starts, and the offsets it cuts in the text of its first and last character. When the hit ends on the space the search adds at a line break, End is 0 and Last is the end offset in the last character before it (-1 if the hit is only that space).</summary>
internal readonly record struct HitCut(int Order, int Index, int Start, int End, int Last);

/// <summary>Collects the pages where a regular expression ran out of time; hits found before the limit are still given.</summary>
public sealed class SearchTimeouts
{
    public List<int> Pages { get; } = [];
}

public static class TextSearch
{
    private static readonly TimeSpan RegexTimeout = TimeSpan.FromSeconds(2);

    /// <summary>
    /// Finds a query on a page. White space in the query matches any run of white space and line
    /// breaks; a hyphen at a line end can be part of the match or not (<c>in-</c> and <c>formation</c>
    /// match "information", <c>well-</c> and <c>known</c> match "well-known"). A regular expression
    /// that takes more than two seconds on a page stops there and the page is added to <paramref name="timeouts"/>. Throws <see cref="ArgumentException"/> for a bad pattern.
    /// </summary>
    public static IReadOnlyList<SearchMatch> Find(TextPage page, string query, TextSearchOptions? options = null, CancellationToken cancel = default, SearchTimeouts? timeouts = null)
    {
        options ??= new TextSearchOptions();
        return Matcher.Create(query, options) is { } matcher ? matcher.Find(page, cancel, timeouts) : [];
    }

    /// <summary>
    /// Finds a query on the pages <paramref name="first"/> to <paramref name="last"/> (0-based,
    /// inclusive), one page at a time as the sequence is read, so that a viewer can show the first hits
    /// while the rest is searched. Stops with <see cref="OperationCanceledException"/>.
    /// </summary>
    public static IEnumerable<SearchMatch> Find(TextCache cache, string query, TextSearchOptions? options = null,
        int first = 0, int last = int.MaxValue, CancellationToken cancel = default, SearchTimeouts? timeouts = null)
    {
        options ??= new TextSearchOptions();
        var matcher = Matcher.Create(query, options);
        return matcher is null ? [] : Pages(cache, matcher, first, last, cancel, timeouts);
    }

    /// <summary>Every hit on a page, several in one character included (hits in a span's replacement text), for a replacement that cuts them out of that text.</summary>
    internal static IReadOnlyList<SearchMatch> FindAll(TextPage page, string query, TextSearchOptions options, CancellationToken cancel) =>
        Matcher.Create(query, options) is { } matcher ? matcher.Find(page, cancel, null, true) : [];

    private static IEnumerable<SearchMatch> Pages(TextCache cache, Matcher matcher, int first, int last, CancellationToken cancel, SearchTimeouts? timeouts)
    {
        int end = Math.Min(last, cache.PageCount - 1);
        for (int p = Math.Max(first, 0); p <= end; p++)
        {
            cancel.ThrowIfCancellationRequested();
            foreach (var match in matcher.Find(cache.Get(p), cancel, timeouts)) yield return match;
        }
    }

    private readonly record struct Hit(TextRange Range, SearchText Searched, int Order, int Index, int Length);

    private sealed class Matcher
    {
        private readonly TextSearchOptions _options;
        private readonly string _query = "";
        private readonly Regex? _regex;

        private Matcher(TextSearchOptions options, string query, Regex? regex)
        {
            _options = options;
            _query = query;
            _regex = regex;
        }

        public static Matcher? Create(string query, TextSearchOptions options)
        {
            if (string.IsNullOrEmpty(query)) return null;
            if (options.Regex)
            {
                string folded = options.FoldDiacritics ? SearchText.StripMarks(query) : query;
                string pattern = options.WholeWord ? $@"(?<![\p{{L}}\p{{N}}])(?:{folded})(?![\p{{L}}\p{{N}}])" : folded;
                var flags = RegexOptions.CultureInvariant | (options.MatchCase ? RegexOptions.None : RegexOptions.IgnoreCase);
                return new Matcher(options, "", new Regex(pattern, flags, RegexTimeout));
            }
            string plain = SearchText.Collapse(SearchText.Fold(query, options));
            return plain.Length == 0 ? null : new Matcher(options, plain, null);
        }

        public IReadOnlyList<SearchMatch> Find(TextPage page, CancellationToken cancel, SearchTimeouts? timeouts, bool all = false)
        {
            var found = new List<Hit>();
            var text = SearchText.Build(page, _options, false);
            bool timedOut = !Collect(text, 0, found, cancel);
            if (text.HasHyphenBreak) timedOut |= !Collect(SearchText.Build(page, _options, true), 1, found, cancel);
            if (timedOut) timeouts?.Pages.Add(page.PageIndex);
            var result = new List<SearchMatch>();
            int end = -1;
            var ordered = all
                ? found.OrderBy(h => h.Range.Start).ThenBy(h => h.Searched.StartOf(h.Index)).ThenByDescending(h => h.Range.End).ThenBy(h => h.Order).ThenBy(h => h.Index)
                : found.OrderBy(h => h.Range.Start).ThenByDescending(h => h.Range.End).ThenBy(h => h.Order).ThenBy(h => h.Index);
            // The search with line-end hyphens dropped finds a copy of every other hit, which would be replaced twice.
            var seen = all ? found.Where(h => h.Order == 0).Select(Key).ToHashSet() : [];
            foreach (var hit in ordered)
            {
                var range = hit.Range;
                if (all && hit.Order == 1 && seen.Contains(Key(hit))) continue;
                if (!all && range.Start < end) continue;
                end = range.End;
                int tip = hit.Index + hit.Length - 1, tipEnd = hit.Searched.EndOf(tip);
                var cut = new HitCut(hit.Order, hit.Index, hit.Searched.StartOf(hit.Index), tipEnd, tipEnd != 0 ? tipEnd : hit.Length > 1 ? hit.Searched.EndOf(tip - 1) : -1);
                result.Add(new SearchMatch(page.PageIndex, range, page.GetText(range, true), page.Quads(range)) { Source = cut });
            }
            return result;
        }

        private static (TextRange, int, int) Key(Hit h) => (h.Range, h.Searched.StartOf(h.Index), h.Searched.EndOf(h.Index + h.Length - 1));

        private bool Collect(SearchText text, int order, List<Hit> found, CancellationToken cancel)
        {
            if (text.Text.Length == 0) return true;
            if (_regex is null)
            {
                for (int from = 0; from <= text.Text.Length - _query.Length;)
                {
                    int i = text.Text.IndexOf(_query, from, StringComparison.Ordinal);
                    if (i < 0) break;
                    from = i + _query.Length;
                    if (_options.WholeWord && !IsWhole(text.Text, i, from))
                    {
                        from = i + 1;
                        continue;
                    }
                    found.Add(new Hit(new TextRange(text.Map[i], text.Map[from - 1] + 1), text, order, i, from - i));
                }
                return true;
            }
            try
            {
                foreach (Match m in _regex.Matches(text.Text))
                {
                    cancel.ThrowIfCancellationRequested();
                    if (m.Length == 0) continue;
                    found.Add(new Hit(new TextRange(text.Map[m.Index], text.Map[m.Index + m.Length - 1] + 1), text, order, m.Index, m.Length));
                }
            }
            catch (RegexMatchTimeoutException)
            {
                return false;
            }
            return true;
        }

        // The edge of the query decides: a query that starts with a punctuation mark has no word edge there.
        private bool IsWhole(string text, int start, int end)
        {
            if (char.IsLetterOrDigit(_query[0]) && start > 0 && char.IsLetterOrDigit(text[start - 1])) return false;
            return !(char.IsLetterOrDigit(_query[^1]) && end < text.Length && char.IsLetterOrDigit(text[end]));
        }
    }
}
