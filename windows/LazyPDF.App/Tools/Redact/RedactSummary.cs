using LazyPDF.Core;

namespace LazyPDF.App.Tools.Redact;

/// <summary>What the panel says once a copy is made: the verdict of the check, what was removed, which pages are pictures now.</summary>
public sealed record RedactSummary(bool Clean, string Title, string Advice, string Report, string Problems, string NotChecked)
{
    public static RedactSummary Of(RedactionResult result, bool flattenedAll = false)
    {
        var report = result.Report;
        var flattened = report.Flattened.Select(RedactionText.Flattened).ToHashSet();
        var lines = report.ToString().Split('\n').Where(l => !flattened.Contains(l)).ToList();
        if (report.Flattened.Count > 0)
        {
            lines.Add(Loc.Plural(report.Flattened.Count, "Page {1} is now a picture. Its text can no longer be selected.",
                                 "Pages {1} are now pictures. Their text can no longer be selected.", PageRanges(report.Flattened)));
        }

        bool clean = result.Verification.IsClean;
        return new RedactSummary(
            clean,
            clean ? Loc.T("Check passed") : Loc.T("Check found problems"),
            clean ? Loc.T("Nothing was found inside the marked places. Read what was not checked below before you share it.") : FailureAdvice(flattenedAll),
            string.Join('\n', lines),
            string.Join('\n', result.Verification.Problems),
            Loc.T("Not checked: the same words in places that are not marked, words inside pictures, and font files."));
    }

    private static string FailureAdvice(bool flattenedAll) => flattenedAll
        ? Loc.T("Do not share this copy yet. Read the problems below.")
        : Loc.T("Do not share this copy yet. Read the problems below. Flattening every marked page may clear them.");

    /// <summary>Pages from 0 as a person writes them: "2-4, 7".</summary>
    public static string PageRanges(IEnumerable<int> pages)
    {
        var parts = new List<string>();
        int[] sorted = [.. pages.Distinct().Order()];
        for (int i = 0; i < sorted.Length;)
        {
            int j = i;
            while (j + 1 < sorted.Length && sorted[j + 1] == sorted[j] + 1) j++;
            parts.Add(j > i ? $"{sorted[i] + 1}-{sorted[j] + 1}" : (sorted[i] + 1).ToString());
            i = j + 1;
        }
        return string.Join(", ", parts);
    }
}
