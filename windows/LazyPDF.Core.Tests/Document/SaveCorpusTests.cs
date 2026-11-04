using System.Text;
using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// With LAZYPDF_CORPUS naming a text file of paths (one per line), every file that opens is
// rewritten, with and without object streams, and updated incrementally with a changed title; the
// results must reopen with the same page count and the same page contents. When
// LAZYPDF_CORPUS_OUT names a folder the results are left there for other readers to check.
public class SaveCorpusTests(ITestOutputHelper output)
{
    private const int MaxPages = 200;
    private const string NewTitle = "Changed by the corpus test";

    private static List<byte[]> Contents(PdfDocument document) =>
        [.. document.Pages.Take(MaxPages).Select(p => p.Contents())];

    [Fact]
    public void EveryFileSurvivesARewriteAndAnUpdate()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;
        string? keep = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS_OUT");
        if (!string.IsNullOrEmpty(keep)) Directory.CreateDirectory(keep);

        int checkedFiles = 0;
        var failures = new List<string>();
        foreach (string path in File.ReadAllLines(list).Select(l => l.Trim()).Where(l => l.Length > 0 && File.Exists(l)))
        {
            PdfDocument document;
            try
            {
                document = PdfDocument.Open(path);
            }
            catch (PdfReadException)
            {
                continue;
            }
            string name = $"{checkedFiles:D4}";
            try
            {
                int pages = document.Pages.Count;
                var contents = Contents(document);
                byte[] source = document.Source.ToArray();

                foreach (bool packed in new[] { false, true })
                {
                    byte[] rewritten = document.SaveRewrite(new PdfSaveOptions(packed, document.Security));
                    Check(PdfDocument.Open(rewritten), pages, contents, packed ? "packed rewrite" : "rewrite", path, failures);
                    if (keep is not null) File.WriteAllBytes(Path.Combine(keep, $"{name}-rewrite{(packed ? "-packed" : "")}.pdf"), rewritten);
                }

                var info = document.Info;
                if (info is null)
                {
                    info = new PdfDictionary();
                    document.Trailer["Info"] = document.Add(info);
                }
                info["Title"] = new PdfString(Encoding.ASCII.GetBytes(NewTitle), isHex: false);
                byte[] updated = document.SaveIncremental();
                if (!updated.AsSpan(0, source.Length).SequenceEqual(source)) failures.Add($"{path}: the update changed the original bytes");
                var again = PdfDocument.Open(updated);
                Check(again, pages, contents, "update", path, failures);
                if (SaveFixtures.Title(again) != NewTitle) failures.Add($"{path}: the new title was not read back");
                if (keep is not null) File.WriteAllBytes(Path.Combine(keep, $"{name}-update.pdf"), updated);
                checkedFiles++;
            }
            catch (Exception e)
            {
                failures.Add($"{path}: {e.GetType().Name} {e.Message} {e.StackTrace?.Split('\n').FirstOrDefault()?.Trim()}");
            }
        }
        output.WriteLine($"checked {checkedFiles} files, {failures.Count} failures");
        Assert.True(failures.Count == 0, string.Join("\n", failures));
    }

    private static void Check(PdfDocument written, int pages, List<byte[]> contents, string what, string path, List<string> failures)
    {
        if (written.Pages.Count != pages)
        {
            failures.Add($"{path}: {what} has {written.Pages.Count} pages, not {pages}");
            return;
        }
        var back = Contents(written);
        for (int i = 0; i < back.Count; i++)
        {
            if (!back[i].AsSpan().SequenceEqual(contents[i]))
            {
                failures.Add($"{path}: {what} changed the contents of page {i + 1}");
                return;
            }
        }
    }
}
