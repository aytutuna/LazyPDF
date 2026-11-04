using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Redacts one word on each of the first pages of every file in the list LAZYPDF_CORPUS names, with the
// metadata changed too. The only thing the check may still find is the word in an attached file, which
// is the user's own data. Does nothing without the variable; only counts are printed.
public class RedactCorpusMetadataTests(ITestOutputHelper output)
{
    private const int MaxPages = 25;

    [Fact]
    public void OutputOfEveryFileVerifiesCleanExceptAttachments()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, clean = 0, attachments = 0, refused = 0;
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
                var problems = new PdfRedactor(document).Apply(marks, new RedactionOptions { ChangeMetadata = true }).Verification.Problems;
                if (problems.Count == 0) clean++;
                else if (problems.All(p => p.Contains("attached file"))) attachments++;
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
        output.WriteLine($"{files} files redacted: {clean} clean, {attachments} with the word in an attachment only, {dirty.Count} not clean, {refused} refused");
        foreach (string d in dirty.Take(20)) output.WriteLine(d);
        Assert.Empty(dirty);
    }
}
