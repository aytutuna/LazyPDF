using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Redacts one word on each of the first pages of every file in the list LAZYPDF_CORPUS names, with the
// metadata changed too. The only thing the check may still find is the word in an attached file, which
// is the user's own data. It may also report that a page nobody marked, or an object no page reaches, could
// not be followed or opened: such a page shares objects with a marked page, so it is not known to be clean.
// Does nothing without the variable; only counts are printed.
public class RedactCorpusMetadataTests(ITestOutputHelper output)
{
    private const int MaxPages = 25;

    // Only what the check could not read: no text found, and the pages it could not follow are not marked.
    private static bool NotChecked(string problem, List<RedactionMark> marks) =>
        problem.EndsWith("so it was not checked.", StringComparison.Ordinal)
        || problem.StartsWith("Page ", StringComparison.Ordinal) && !marks.Any(m => problem == RedactionText.NotFollowed(m.Page));

    [Fact]
    public void OutputOfEveryFileVerifiesCleanExceptAttachments()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, clean = 0, attachments = 0, unread = 0, refused = 0, flattened = 0;
        var dirty = new List<string>();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            try
            {
                using var document = PdfDocument.Open(path);
                var marks = new List<RedactionMark>();
                for (int p = 0; p < Math.Min(MaxPages, document.Pages.Count); p++)
                {
                    var text = TextPage.Create(document, document.Pages[p]);
                    var words = text.Words.Where(w => w.Text.Length >= 4 && w.Text.Any(char.IsLetterOrDigit)).ToList();
                    if (words.Count > 0) marks.Add(new RedactionMark(p, text.Quads(words[words.Count / 2].Range)));
                }
                if (marks.Count == 0) continue;
                files++;
                var result = new PdfRedactor(document).Apply(marks, RedactionKit.Drawing(document, new RedactionOptions { ChangeMetadata = true }));
                flattened += result.Report.Flattened.Count;
                var problems = result.Verification.Problems;
                if (problems.Count == 0) clean++;
                else if (problems.All(p => p.Contains("attached file"))) attachments++;
                else if (problems.All(p => NotChecked(p, marks))) unread++;
                else dirty.Add($"file {files}: {problems.Count} problems");
            }
            catch (PdfReadException)
            {
            }
            catch (InvalidOperationException)
            {
                refused++;
            }
        }
        output.WriteLine($"{files} files redacted: {clean} clean, {attachments} with the word in an attachment only, {unread} not fully checked, {dirty.Count} not clean, {refused} refused, {flattened} pages flattened");
        foreach (string d in dirty.Take(20)) output.WriteLine(d);
        Assert.Empty(dirty);
    }
}
