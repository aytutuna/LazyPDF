using System.Diagnostics;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Runs every page of every file in the list LAZYPDF_CORPUS names (one path per line) through the
// text engine; does nothing without it. Only counts and times are printed.
public class TextCorpusTests(ITestOutputHelper output)
{
    [Fact]
    public void EveryPageGivesConsistentText()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, pages = 0, withText = 0, searched = 0, found = 0;
        long chars = 0;
        var times = new List<double>();
        var problems = new List<string>();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            try
            {
                using var document = PdfDocument.Open(path);
                files++;
                var interpreter = new ContentInterpreter(document);
                foreach (var pdfPage in document.Pages)
                {
                    var watch = Stopwatch.StartNew();
                    var page = TextPage.Create(interpreter, pdfPage);
                    watch.Stop();
                    pages++;
                    chars += page.Chars.Count;
                    if (page.Chars.Count > 200) times.Add(watch.Elapsed.TotalMilliseconds);
                    if (page.Chars.Count == 0) continue;
                    withText++;
                    string? problem = TextInvariants.Check(page);
                    if (problem is not null && problems.Count < 20) problems.Add(problem);
                    var word = page.Words.FirstOrDefault(w => w.Text.Length >= 5 && w.Text.All(char.IsLetter));
                    if (word is null) continue;
                    searched++;
                    var hits = TextSearch.Find(page, word.Text);
                    if (hits.Any(h => h.Range.Start <= word.Range.Start && h.Range.End >= word.Range.End)) found++;
                }
            }
            catch (PdfReadException)
            {
            }
            catch (Exception e)
            {
                problems.Add($"{e.GetType().Name} at {e.StackTrace?.Split('\n').FirstOrDefault()?.Trim()}");
            }
        }
        times.Sort();
        output.WriteLine($"{files} files, {pages} pages ({withText} with text), {chars} chars; search found its own word on {found} of {searched} pages");
        if (times.Count > 0) output.WriteLine($"ms per page: median {times[times.Count / 2]:0.0}, p90 {times[times.Count * 9 / 10]:0.0}, max {times[^1]:0.0}");
        Assert.True(problems.Count == 0, string.Join("\n", problems));
        Assert.True(found >= searched * 0.99, $"search found its own word on {found} of {searched} pages");
    }
}
