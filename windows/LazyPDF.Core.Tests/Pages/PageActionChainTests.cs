using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageActionChainTests
{
    // Links 100 to 100 + Levels: each action names the next one three times.
    private const int Levels = 32;

    private static byte[] Fan() => PageTestFiles.Make(2, pageExtra: i => i == 0 ? "/Annots [99 0 R]" : "", add: pdf =>
    {
        pdf.Obj(99, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A 100 0 R>>");
        for (int i = 0; i <= Levels; i++)
        {
            string next = i == Levels ? "" : $"/Next [{101 + i} 0 R {101 + i} 0 R {101 + i} 0 R]";
            pdf.Obj(100 + i, $"<</S /Named /N /NextPage {next}>>");
        }
    });

    [Fact]
    public async Task ImportingAFanOfActionsEnds()
    {
        var source = PdfDocument.Open(Fan());
        var target = PageTestFiles.Open(1);

        await Task.Run(() => PageOperations.ImportPages(target, source, [0], 1)).WaitAsync(TimeSpan.FromSeconds(20));
    }

    [Fact]
    public async Task DeletingAnotherPageWithAFanOfActionsEnds()
    {
        var document = PdfDocument.Open(Fan());

        await Task.Run(() => PageOperations.Delete(document, [1])).WaitAsync(TimeSpan.FromSeconds(20));
    }

    [Fact]
    public void OpenActionKeepsBeingOneActionWhenItsGoToIsDropped()
    {
        var document = PageTestFiles.Open(2, "/OpenAction 20 0 R", add: pdf => pdf
            .Obj(20, "<</S /GoTo /D [5 0 R /Fit] /Next [21 0 R 22 0 R [21 0 R]]>>")
            .Obj(21, "<</S /URI /URI (http://a)>>")
            .Obj(22, "<</S /URI /URI (http://b)>>"));

        PageOperations.Delete(document, [1]);

        var action = Assert.IsType<PdfDictionary>(document.Resolve(document.Catalog["OpenAction"]));
        Assert.Equal("URI", document.Name(action, "S"));
        var rest = Assert.IsType<PdfArray>(document.Resolve(action["Next"]));
        var follower = Assert.IsType<PdfDictionary>(document.Resolve(Assert.Single(rest.Items)));
        Assert.Equal("URI", document.Name(follower, "S"));
        Assert.NotSame(action, follower);
    }

    [Fact]
    public async Task ALongArticleThreadIsWalkedInLinearTime()
    {
        const int Beads = 120_000;
        int free = PageTestFiles.Free(2);
        var document = PageTestFiles.Open(2, $"/Threads [{free} 0 R]", add: pdf =>
        {
            pdf.Obj(free, $"<</Type /Thread /F {free + 1} 0 R>>");
            for (int i = 0; i < Beads; i++)
            {
                int next = free + 1 + (i + 1) % Beads, previous = free + 1 + (i + Beads - 1) % Beads;
                pdf.Obj(free + 1 + i, $"<</Type /Bead /N {next} 0 R /V {previous} 0 R /P {(i == 0 ? 5 : 4)} 0 R /R [0 0 1 1]>>");
            }
        });

        await Task.Run(() => PageOperations.Delete(document, [1])).WaitAsync(TimeSpan.FromSeconds(120));

        var thread = (PdfDictionary)document.Resolve(document.Array(document.Catalog, "Threads")!.Items[0])!;
        Assert.NotNull(thread["F"]);
    }
}
