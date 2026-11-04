using System.Text.RegularExpressions;

namespace LazyPDF.Core;

/// <summary>How a search reads its query.</summary>
/// <param name="MatchCase">Capitals must match; by default they do not matter (dotless i stays a different letter from i).</param>
/// <param name="WholeWord">The match may not touch a letter or digit on either side.</param>
/// <param name="Regex">The query is a regular expression over the text of the page, where a line break is one space.</param>
/// <param name="FoldDiacritics">Accents and marks do not matter, and I, dotted and dotless I and i are all the same letter.</param>
public sealed record TextSearchOptions(bool MatchCase = false, bool WholeWord = false, bool Regex = false, bool FoldDiacritics = false);

/// <summary>A hit: the page, its characters and the boxes to paint, one for each line it crosses.</summary>
public sealed record SearchMatch(int Page, TextRange Range, string Text, IReadOnlyList<TextQuad> Quads);

public static class TextSearch
{
    private static readonly TimeSpan RegexTimeout = TimeSpan.FromSeconds(2);

    /// <summary>
    /// Finds a query on a page. White space in the query matches any run of white space and line
    /// breaks; a hyphen at a line end can be part of the match or not (<c>in-</c> and <c>formation</c>
    /// match "information", <c>well-</c> and <c>known</c> match "well-known"). A regular expression
    /// that takes more than two seconds on a page gives no hits for it. Throws <see cref="ArgumentException"/> for a bad pattern.
    /// </summary>
    public static IReadOnlyList<SearchMatch> Find(TextPage page, string query, TextSearchOptions? options = null, CancellationToken cancel = default)
    {
        options ??= new TextSearchOptions();
        return Matcher.Create(query, options) is { } matcher ? matcher.Find(page, cancel) : [];
    }

    /// <summary>
    /// Finds a query on the pages <paramref name="first"/> to <paramref name="last"/> (0-based,
    /// inclusive), one page at a time as the sequence is read, so that a viewer can show the first hits
    /// while the rest is searched. Stops with <see cref="OperationCanceledException"/>.
    /// </summary>
    public static IEnumerable<SearchMatch> Find(TextCache cache, string query, TextSearchOptions? options = null,
        int first = 0, int last = int.MaxValue, CancellationToken cancel = default)
    {
        options ??= new TextSearchOptions();
        var matcher = Matcher.Create(query, options);
        return matcher is null ? [] : Pages(cache, matcher, first, last, cancel);
    }

    private static IEnumerable<SearchMatch> Pages(TextCache cache, Matcher matcher, int first, int last, CancellationToken cancel)
    {
        int end = Math.Min(last, cache.PageCount - 1);
        for (int p = Math.Max(first, 0); p <= end; p++)
        {
            cancel.ThrowIfCancellationRequested();
            foreach (var match in matcher.Find(cache.Get(p), cancel)) yield return match;
        }
    }

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

        public IReadOnlyList<SearchMatch> Find(TextPage page, CancellationToken cancel)
        {
            var found = new List<TextRange>();
            var text = SearchText.Build(page, _options, false);
            Collect(text, found, cancel);
            if (text.HasHyphenBreak) Collect(SearchText.Build(page, _options, true), found, cancel);
            found.Sort((a, b) => a.Start != b.Start ? a.Start.CompareTo(b.Start) : b.End.CompareTo(a.End));
            var result = new List<SearchMatch>();
            int end = -1;
            foreach (var range in found)
            {
                if (range.Start < end) continue;
                end = range.End;
                result.Add(new SearchMatch(page.PageIndex, range, page.GetText(range, true), page.Quads(range)));
            }
            return result;
        }

        private void Collect(SearchText text, List<TextRange> found, CancellationToken cancel)
        {
            if (text.Text.Length == 0) return;
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
                    found.Add(new TextRange(text.Map[i], text.Map[from - 1] + 1));
                }
                return;
            }
            try
            {
                foreach (Match m in _regex.Matches(text.Text))
                {
                    cancel.ThrowIfCancellationRequested();
                    if (m.Length == 0) continue;
                    found.Add(new TextRange(text.Map[m.Index], text.Map[m.Index + m.Length - 1] + 1));
                }
            }
            catch (RegexMatchTimeoutException)
            {
            }
        }

        // The edge of the query decides: a query that starts with a punctuation mark has no word edge there.
        private bool IsWhole(string text, int start, int end)
        {
            if (char.IsLetterOrDigit(_query[0]) && start > 0 && char.IsLetterOrDigit(text[start - 1])) return false;
            return !(char.IsLetterOrDigit(_query[^1]) && end < text.Length && char.IsLetterOrDigit(text[end]));
        }
    }
}
