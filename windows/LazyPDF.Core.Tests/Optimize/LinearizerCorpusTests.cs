using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// With LAZYPDF_CORPUS naming a text file of paths (one per line), every file that opens and has
// pages is linearized, reopened and compared with the original for page count and text, and the
// layout and hint tables are checked. With LAZYPDF_CORPUS_OUT naming a folder the results are left
// there for other readers. Only counts are printed.
public class LinearizerCorpusTests(ITestOutputHelper output)
{
    private const int TextPages = 12;
    private const long CheckLimit = 40L << 20;

    private static string Text(PdfDocument document)
    {
        var cache = new TextCache(document);
        return string.Join("\f", Enumerable.Range(0, Math.Min(TextPages, document.Pages.Count)).Select(i => cache.Get(i).Text));
    }

    private static int? PigPages(byte[] file)
    {
        try
        {
            using var pig = UglyToad.PdfPig.PdfDocument.Open(file);
            return pig.NumberOfPages;
        }
        catch (Exception)
        {
            return null;
        }
    }

    [Fact]
    public void EveryFileSurvivesLinearization()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;
        string? keep = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS_OUT");
        if (!string.IsNullOrEmpty(keep)) Directory.CreateDirectory(keep);

        int files = 0, done = 0, refused = 0, verified = 0, pigReads = 0;
        var failures = new List<string>();
        foreach (string path in File.ReadAllLines(list).Select(l => l.Trim()).Where(l => l.Length > 0 && File.Exists(l)))
        {
            files++;
            try
            {
                using var document = PdfDocument.Open(path);
                if (document.Pages.Count == 0) continue;
                string text = Text(document);
                byte[] linear = document.SaveLinearized(new PdfSaveOptions(Security: document.Security));
                if (keep is not null) File.WriteAllBytes(Path.Combine(keep, $"{files:D4}.pdf"), linear);

                using var again = PdfDocument.Open(linear);
                if (!again.IsLinearized) failures.Add($"{files}: not linearized");
                if (again.Pages.Count != document.Pages.Count) failures.Add($"{files}: page count {again.Pages.Count}, was {document.Pages.Count}");
                else if (Text(again) != text) failures.Add($"{files}: text differs");
                if (linear.Length < CheckLimit && !document.IsEncrypted)
                {
                    LinearizerKit.Verify(linear);
                    verified++;
                    if (PigPages(document.Source.ToArray()) is { } expected)
                    {
                        if (PigPages(linear) != expected) failures.Add($"{files}: PdfPig reads {PigPages(linear)} pages, not {expected}");
                        pigReads++;
                    }
                }
                done++;
            }
            catch (PdfReadException)
            {
                refused++;
            }
            catch (Exception e)
            {
                failures.Add($"{files}: {e.GetType().Name} {e.Message.Split('\n')[0]}");
            }
        }
        output.WriteLine($"{files} files, {done} linearized, {verified} checked in full, {pigReads} read by PdfPig, {refused} not opened, {failures.Count} failures");
        Assert.True(failures.Count == 0, string.Join("\n", failures));
    }
}
