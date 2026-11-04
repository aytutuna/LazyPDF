using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Opens every file in a list when LAZYPDF_CORPUS names a text file of paths (one per line); does
// nothing otherwise. Each file must open or fail with PdfReadException, and the same goes for
// reading its pages. Only counts and sizes are printed.
public class CorpusTests(ITestOutputHelper output)
{
    [Fact]
    public void EveryFileOpensOrFailsCleanly()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int opened = 0, refused = 0, repaired = 0, pages = 0;
        long bytes = 0;
        var other = new List<string>();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            long size = new FileInfo(path).Length;
            try
            {
                using var document = PdfDocument.Open(path);
                opened++;
                bytes += size;
                if (document.Repairs.Count > 0) repaired++;
                pages += document.Pages.Count;
                foreach (var page in document.Pages.Take(20))
                {
                    _ = page.MediaBox;
                    _ = new PageGeometry(page);
                    page.Contents();
                }
                _ = document.PdfAPart;
                _ = document.IsSigned;
            }
            catch (PdfReadException e)
            {
                refused++;
                output.WriteLine($"refused {e.Problem}, {size} bytes");
            }
            catch (Exception e)
            {
                other.Add($"{e.GetType().Name} at {e.StackTrace?.Split('\n').FirstOrDefault()?.Trim()} ({size} bytes)");
            }
        }
        output.WriteLine($"opened {opened} ({bytes / 1024} KB), repaired {repaired}, refused {refused}, {pages} pages");
        Assert.True(other.Count == 0, string.Join("\n", other));
    }
}
