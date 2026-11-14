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

/// <summary>A hit in the searched text: which text (0, or 1 with line-end hyphens dropped), where it starts, and the offsets it cuts in the text of its first and last character.</summary>
internal readonly record struct HitCut(int Order, int Index, int Start, int End);

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

        public IReadOnlyList<SearchMatch> Find(TextPage page, CancellationToken cancel, SearchTimeouts? timeouts)
        {
            var found = new List<Hit>();
            var text = SearchText.Build(page, _options, false);
            bool timedOut = !Collect(text, 0, found, cancel);
            if (text.HasHyphenBreak) timedOut |= !Collect(SearchText.Build(page, _options, true), 1, found, cancel);
            if (timedOut) timeouts?.Pages.Add(page.PageIndex);
            var result = new List<SearchMatch>();
            int end = -1;
            Hit? last = null;
            foreach (var hit in found.OrderBy(h => h.Range.Start).ThenByDescending(h => h.Range.End).ThenBy(h => h.Order).ThenBy(h => h.Index))
            {
                var range = hit.Range;
                // Several hits in the text of one character (a span's replacement text) are all kept.
                bool sameChar = last is { } l && range == l.Range && range.End == range.Start + 1 && hit.Order == l.Order && hit.Index >= l.Index + l.Length;
                if (range.Start < end && !sameChar) continue;
                end = range.End;
                last = hit;
                var cut = new HitCut(hit.Order, hit.Index, hit.Searched.StartOf(hit.Index), hit.Searched.EndOf(hit.Index + hit.Length - 1));
                result.Add(new SearchMatch(page.PageIndex, range, page.GetText(range, true), page.Quads(range)) { Source = cut });
            }
            return result;
        }

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
