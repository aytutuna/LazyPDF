using System.Text;
using System.Text.RegularExpressions;

namespace LazyPDF.Core;

/// <summary>A match that was not replaced, and why.</summary>
public sealed record ReplaceFailure(int Page, string Text, string Reason);

/// <summary>What <see cref="TextReplacer.ReplaceAll"/> did.</summary>
/// <param name="Replaced">Matches replaced.</param>
/// <param name="Failed">Matches left as they were.</param>
/// <param name="Pages">Pages that changed.</param>
public sealed record ReplaceReport(int Replaced, IReadOnlyList<ReplaceFailure> Failed, IReadOnlyList<FontSubstitution> Substitutions, IReadOnlyList<int> Pages);

/// <summary>Find and replace through a whole document, committed as one step.</summary>
public static class TextReplacer
{
    private static readonly Regex GroupReference = new(@"\$(?:(\$)|(&)|([`'+_])|(\d+)|\{(\w+)\})", RegexOptions.CultureInvariant);

    /// <summary>
    /// Replaces every match of <paramref name="query"/> (searched as <see cref="TextSearch"/> does,
    /// with the same options) in the document of <paramref name="session"/> and commits once. With
    /// <see cref="TextSearchOptions.Regex"/> the replacement may use groups ($1). A match that runs
    /// over two lines, or that no font can show, stays as it was and is reported.
    /// </summary>
    public static ReplaceReport ReplaceAll(PdfEditSession session, string query, string replacement, TextSearchOptions? options = null,
        IFontSource? fonts = null, string label = "Replace text", CancellationToken cancel = default)
    {
        options ??= new TextSearchOptions();
        var document = session.Document;
        var failures = new List<ReplaceFailure>();
        var substitutions = new List<FontSubstitution>();
        var changed = new List<int>();
        int replaced = 0;
        for (int p = 0; p < document.Pages.Count; p++)
        {
            cancel.ThrowIfCancellationRequested();
            var model = PageModel.Load(document, p);
            var hits = TextSearch.FindAll(model.Text, query, options, cancel);
            if (hits.Count == 0) continue;
            // A hit that ends on the space the search adds at a line break runs over two lines, or is only that space; it is never
            // written, since the space is no character of the next line and its range would cut that line's first one.
            var matches = new List<SearchMatch>();
            foreach (var match in hits)
            {
                var cut = match.Source!.Value;
                if (cut.End != 0) matches.Add(match);
                else failures.Add(new ReplaceFailure(p, match.Text, cut.OnlyBreak ? EditingText.NothingChanged : EditingText.CrossesLines));
            }
            if (matches.Count == 0) continue;
            var batch = new EditBatch(document, model.Page, model.Scan);
            var builder = new TextBuilder(document, batch, fonts);
            var editor = new TextEditor(model, batch, builder, fonts);
            var expanded = Expansions(model, query, replacement, options);
            var done = new List<SearchMatch>();
            foreach (var group in Clusters(model, matches))
            {
                var mark = batch.Save();
                try
                {
                    var range = new TextRange(group[0].Range.Start, group[^1].Range.End);
                    if (LinesOf(model, range) > 1) throw new EditConflictException(EditingText.CrossesLines);
                    // Expansions stops at a time limit of its own; a group token left for a match after that would be written as it is.
                    var texts = group.Select(m =>
                    {
                        if (expanded.TryGetValue((m.Source!.Value.Order, m.Source.Value.Index), out string? found)) return found;
                        if (options.Regex && replacement.Contains('$')) throw new EditConflictException(EditingText.NothingChanged);
                        return replacement;
                    }).ToList();
                    editor.Replace(range, Splice(model, group, texts));
                    done.AddRange(group);
                }
                catch (EditConflictException e)
                {
                    batch.Restore(mark);
                    failures.AddRange(group.Select(m => new ReplaceFailure(p, m.Text, e.Message)));
                }
            }
            if (done.Count == 0) continue;
            try
            {
                batch.Apply();
                builder.WriteAdditions();
            }
            catch (EditConflictException e)
            {
                batch.Discard();
                failures.AddRange(done.Select(m => new ReplaceFailure(p, m.Text, e.Message)));
                continue;
            }
            replaced += done.Count;
            changed.Add(p);
            substitutions.AddRange(builder.Substitutions);
        }
        if (replaced > 0) session.Commit(label);
        return new ReplaceReport(replaced, failures, substitutions, changed);
    }

    // The hits to replace, in groups that are edited together: hits in the text of one span share its character (a hit that
    // runs on into the next span shares the character it ends in), so a hit that starts where the one before ended in a span
    // is taken in with it. Any other hit that overlaps the one before is left out.
    private static List<List<SearchMatch>> Clusters(PageModel model, IReadOnlyList<SearchMatch> matches)
    {
        var groups = new List<List<SearchMatch>>();
        int lastEnd = -1, lastCut = 0;
        foreach (var match in matches)
        {
            var (range, cut) = (match.Range, match.Source!.Value);
            if (range.Start >= lastEnd) groups.Add([match]);
            else if (range.Start == lastEnd - 1 && cut.Start >= lastCut && InSpan(model, range.Start) is not null) groups[^1].Add(match);
            else continue;
            (lastEnd, lastCut) = (range.End, cut.End);
        }
        return groups;
    }

    // A character that stands for /ActualText is the text of a whole span, and an edit takes the span's glyphs together, so
    // what the hits leave of that text goes back around the replacements.
    private static string Splice(PageModel model, List<SearchMatch> group, List<string> texts)
    {
        var cuts = group.Select(m => m.Source!.Value).ToList();
        var sb = new StringBuilder();
        if (InSpan(model, group[0].Range.Start) is { } head) sb.Append(head, 0, cuts[0].Start);
        for (int i = 0; i < group.Count; i++)
        {
            if (i > 0 && InSpan(model, group[i].Range.Start) is { } shared) sb.Append(shared, cuts[i - 1].End, cuts[i].Start - cuts[i - 1].End);
            sb.Append(texts[i]);
        }
        if (InSpan(model, group[^1].Range.End - 1) is { } tail) sb.Append(tail, cuts[^1].End, tail.Length - cuts[^1].End);
        return sb.ToString();
    }

    // The text of a character that holds more than one letter (a span's replacement text, a ligature), which a hit may cut part of.
    private static string? InSpan(PageModel model, int index)
    {
        if (index < 0 || index >= model.CharGlyphs.Length || model.CharGlyphs[index] is not { } glyph || model.Text.Chars[index].IsSpace) return null;
        string text = model.Text.Chars[index].Text;
        return glyph.Span is not null || text.EnumerateRunes().Skip(1).Any() ? text : null;
    }

    private sealed class Unmappable : Exception;

    // The page text of the searched characters from `index` for `length`, where a span's character gives only the part of its text the range takes.
    private static string PageText(PageModel model, SearchText searched, int index, int length)
    {
        // A piece that ends on the space the search adds at a line break stops before it; the caller keeps the white space of the searched text.
        if (searched.EndOf(index + length - 1) == 0)
        {
            if (length == 1) return "";
            length--;
        }
        var range = RangeOf(searched, index, length);
        string full = model.Text.GetText(range, true);
        string? first = InSpan(model, range.Start), last = InSpan(model, range.End - 1);
        int start = searched.StartOf(index), end = searched.EndOf(index + length - 1);
        if (range.End - range.Start == 1 && first is not null)
        {
            if (full != first || start > end) throw new Unmappable();
            return first[start..end].Trim();
        }
        if (first is not null)
        {
            if (!full.StartsWith(first, StringComparison.Ordinal)) throw new Unmappable();
            full = first[start..] + full[first.Length..];
        }
        if (last is not null)
        {
            if (!full.EndsWith(last, StringComparison.Ordinal)) throw new Unmappable();
            full = full[..^last.Length] + last[..end];
        }
        // As the page text of a range, which has no white space at its ends.
        return first is null && last is null ? full : full.Trim();
    }

    private static int LinesOf(PageModel model, TextRange range)
    {
        var lines = new HashSet<int>();
        for (int i = range.Start; i < range.End && i < model.CharGlyphs.Length; i++)
        {
            if (model.CharGlyphs[i] is not null) lines.Add(model.Text.Chars[i].Line);
        }
        return lines.Count;
    }

    // The replacement of each regex match, found on the text TextSearch runs (folded as the options ask) so that every
    // match it reports has an entry. Lookarounds and the whole-word edges see the page; a group is the page's own text,
    // with its case and accents, taken back through the map.
    private static Dictionary<(int Order, int Index), string> Expansions(PageModel model, string query, string replacement, TextSearchOptions options)
    {
        var found = new Dictionary<(int, int), string>();
        var text = model.Text;
        if (!options.Regex) return found;
        string folded = options.FoldDiacritics ? SearchText.StripMarks(query) : query;
        string pattern = options.WholeWord ? $@"(?<![\p{{L}}\p{{N}}])(?:{folded})(?![\p{{L}}\p{{N}}])" : folded;
        var flags = RegexOptions.CultureInvariant | (options.MatchCase ? RegexOptions.None : RegexOptions.IgnoreCase);
        var regex = new Regex(pattern, flags, TimeSpan.FromSeconds(2));
        try
        {
            foreach (bool dropHyphens in new[] { false, true })
            {
                var searched = SearchText.Build(text, options, dropHyphens);
                foreach (Match m in regex.Matches(searched.Text))
                {
                    if (m.Length == 0) continue;
                    try
                    {
                        found.TryAdd((dropHyphens ? 1 : 0, m.Index), Expand(model, searched, regex, m, replacement));
                    }
                    catch (Unmappable)
                    {
                    }
                }
                if (!searched.HasHyphenBreak) break;
            }
        }
        catch (RegexMatchTimeoutException)
        {
        }
        return found;
    }

    private static TextRange RangeOf(SearchText searched, int index, int length) =>
        new(searched.Map[index], searched.Map[index + length - 1] + 1);

    // The tokens .NET expands from the searched text ($&, $+, $`, $', $_) are taken from the page as well; $$ is left for Result.
    private static string Expand(PageModel model, SearchText searched, Regex regex, Match m, string replacement)
    {
        // The page text of a range loses the white space at its ends, which a group or the text around a match may be made of.
        string Page(int index, int length)
        {
            if (length == 0) return "";
            string seen = searched.Text.Substring(index, length);
            string core = PageText(model, searched, index, length);
            string lead = seen[..(seen.Length - seen.TrimStart().Length)];
            string trail = lead.Length == seen.Length ? "" : seen[seen.TrimEnd().Length..];
            return (lead + core + trail).Replace("$", "$$");
        }
        string Group(int number)
        {
            var group = m.Groups[number];
            return Page(group.Index, group.Length);
        }
        string withPage = GroupReference.Replace(replacement, token =>
        {
            if (token.Groups[1].Success) return token.Value;
            if (token.Groups[2].Success) return Group(0);
            switch (token.Groups[3].Value)
            {
                case "`": return Page(0, m.Index);
                case "'": return Page(m.Index + m.Length, searched.Text.Length - m.Index - m.Length);
                case "_": return Page(0, searched.Text.Length);
                case "+": return Group(regex.GetGroupNumbers().Max());
            }
            // Result reads the ASCII digits after a $ as the number, so any other digit after them is text, and a number
            // past int.MaxValue is left in the token for Result to refuse. A number is a group even when the group is named.
            bool braces = token.Groups[5].Success;
            string name = braces ? token.Groups[5].Value : token.Groups[4].Value;
            int digits = 0;
            while (digits < name.Length && char.IsAsciiDigit(name[digits])) digits++;
            if (digits == 0)
            {
                int named = braces ? regex.GroupNumberFromName(name) : -1;
                return named < 0 ? token.Value : Group(named);
            }
            if (braces && digits < name.Length) return token.Value;
            if (!int.TryParse(name[..digits], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out int number)) return token.Value;
            return regex.GetGroupNumbers().Contains(number) ? Group(number) + name[digits..] : token.Value;
        });
        return m.Result(withPage);
    }
}
