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
            var matches = TextSearch.Find(model.Text, query, options, cancel);
            if (matches.Count == 0) continue;
            var batch = new EditBatch(document, model.Page, model.Scan);
            var builder = new TextBuilder(document, batch, fonts);
            var editor = new TextEditor(model, batch, builder, fonts);
            var expanded = Expansions(model.Text, query, replacement, options);
            var done = new List<SearchMatch>();
            foreach (var match in matches)
            {
                var mark = batch.Save();
                try
                {
                    if (LinesOf(model, match.Range) > 1) throw new EditConflictException(EditingText.CrossesLines);
                    // Expansions stops at a time limit of its own; a group token left for a match after that would be written as it is.
                    if (!expanded.TryGetValue(match.Range, out string? text))
                    {
                        if (options.Regex && replacement.Contains('$')) throw new EditConflictException(EditingText.NothingChanged);
                        text = replacement;
                    }
                    editor.Replace(match.Range, text);
                    done.Add(match);
                }
                catch (EditConflictException e)
                {
                    batch.Restore(mark);
                    failures.Add(new ReplaceFailure(p, match.Text, e.Message));
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
    private static Dictionary<TextRange, string> Expansions(TextPage text, string query, string replacement, TextSearchOptions options)
    {
        var found = new Dictionary<TextRange, string>();
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
                    if (m.Length > 0) found.TryAdd(RangeOf(searched, m.Index, m.Length), Expand(text, searched, regex, m, replacement));
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
    private static string Expand(TextPage text, SearchText searched, Regex regex, Match m, string replacement)
    {
        // The page text of a range loses the white space at its ends, which a group or the text around a match may be made of.
        string Page(int index, int length)
        {
            if (length == 0) return "";
            string seen = searched.Text.Substring(index, length);
            string core = text.GetText(RangeOf(searched, index, length), true);
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
