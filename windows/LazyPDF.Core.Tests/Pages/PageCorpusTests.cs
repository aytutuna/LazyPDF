using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Runs the page tools over every file in a list when LAZYPDF_CORPUS names a text file of paths (one per
// line); does nothing otherwise. Each result must reopen with the page count the edit calls for.
// Only counts are printed.
public class PageCorpusTests(ITestOutputHelper output)
{
    [Fact]
    public void EveryFileSurvivesTheEdits()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int tried = 0, refused = 0, extracted = 0, edited = 0, merged = 0;
        var problems = new List<string>();
        PdfDocument? previous = null;
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0 && File.Exists(l)))
        {
            PdfDocument document;
            try
            {
                document = PdfDocument.Open(path);
            }
            catch (PdfReadException)
            {
                refused++;
                continue;
            }
            tried++;
            int count = document.Pages.Count;
            if (count == 0) continue;
            string step = "extract";
            try
            {
                var first = PageAssembly.Extract(document, [.. Enumerable.Range(0, Math.Min(count, 3))]);
                Reopens(first, Math.Min(count, 3));
                extracted++;

                if (count > 1)
                {
                    step = "edit";
                    var copy = PdfDocument.Open(path);
                    PageOperations.Rotate(copy, [0], 90);
                    PageOperations.Move(copy, [count - 1], 0);
                    PageOperations.Delete(copy, [1]);
                    PageOperations.Duplicate(copy, [0]);
                    PageOperations.InsertBlank(copy, 0, 200, 200);
                    Reopens(copy, count + 1);
                    edited++;

                    step = "session";
                    var session = PdfEditSession.Open(path);
                    PageOperations.Delete(session.Document, [0]);
                    PageOperations.Rotate(session.Document, [0], 90);
                    Assert.True(session.Commit("Edit"));
                    Assert.Equal(count - 1, PdfDocument.Open(session.Current.ToArray()).Pages.Count);
                    Assert.True(session.Undo());
                    Assert.Equal(count, session.Document.Pages.Count);
                }

                if (previous is not null)
                {
                    step = "merge";
                    var both = PageAssembly.Merge([new MergeSource(previous, [0]), new MergeSource(document, [0])]);
                    Reopens(both, 2);
                    merged++;
                }
                previous = document;
            }
            catch (Exception e)
            {
                problems.Add($"{step}: {e.GetType().Name} {e.Message} at {e.StackTrace?.Split('\n').FirstOrDefault()?.Trim()} ({new FileInfo(path).Length} bytes)");
            }
        }
        output.WriteLine($"opened {tried}, refused {refused}, extracted {extracted}, edited {edited}, merged {merged}, problems {problems.Count}");
        Assert.True(problems.Count == 0, string.Join("\n", problems));
    }

    private static void Reopens(PdfDocument document, int pages)
    {
        var again = PdfDocument.Open(document.SaveRewrite());
        Assert.Equal(pages, again.Pages.Count);
        Assert.Empty(again.Repairs);
    }
}
