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
            var done = new List<SearchMatch>();
            foreach (var match in matches)
            {
                var mark = batch.Save();
                try
                {
                    if (LinesOf(model, match.Range) > 1) throw new EditConflictException(EditingText.CrossesLines);
                    editor.Replace(match.Range, Replacement(match.Text, query, replacement, options));
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

    private static string Replacement(string matched, string query, string replacement, TextSearchOptions options)
    {
        if (!options.Regex) return replacement;
        try
        {
            var flags = RegexOptions.CultureInvariant | (options.MatchCase ? RegexOptions.None : RegexOptions.IgnoreCase);
            return new Regex(query, flags, TimeSpan.FromSeconds(2)).Replace(matched, replacement, 1);
        }
        catch (Exception e) when (e is ArgumentException or RegexMatchTimeoutException)
        {
            return replacement;
        }
    }
}
