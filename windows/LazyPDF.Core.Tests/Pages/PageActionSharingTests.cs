using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageActionSharingTests
{
    private static PdfDictionary Dict(PdfDocument document, int number) => Assert.IsType<PdfDictionary>(document.Get(number));

    [Theory]
    [InlineData("[]")]
    [InlineData("[1 2]")]
    [InlineData("[(x)]")]
    [InlineData("7")]
    [InlineData("(x)")]
    public void ADeadGoToAtTheDepthLimitLeavesNoFollowerThatIsNotAnAction(string next)
    {
        var document = PageTestFiles.Open(2, "/OpenAction 20 0 R", add: pdf =>
        {
            for (int i = 0; i < 32; i++) pdf.Obj(20 + i, $"<</S /URI /URI (http://a) /Next {21 + i} 0 R>>");
            pdf.Obj(52, $"<</S /GoTo /D [5 0 R /Fit] /Next {next}>>");
        });

        PageOperations.Delete(document, [1]);

        Assert.False(Dict(document, 51).ContainsKey("Next"));
    }

    [Theory]
    [InlineData("7")]
    [InlineData("(x)")]
    [InlineData("[7 (x)]")]
    public void ActionsAreDictionariesAfterTheirGoToIsDropped(string next)
    {
        var document = PageTestFiles.Open(2, "/OpenAction 20 0 R", pageExtra: i => i == 0 ? "/Annots [90 0 R]" : "", add: pdf => pdf
            .Obj(20, $"<</S /GoTo /D [5 0 R /Fit] /Next {next}>>")
            .Obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 20 0 R>>"));

        PageOperations.Delete(document, [1]);

        Assert.Null(document.Catalog["OpenAction"]);
        Assert.False(Dict(document, 90).ContainsKey("A"));
    }

    [Fact]
    public void AnActionSharedByTwoLinksIsNotEditedForEach()
    {
        var document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? "/Annots [90 0 R 91 0 R]" : "", add: pdf => pdf
            .Obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 20 0 R>>")
            .Obj(91, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 20 0 R>>")
            .Obj(20, "<</S /GoTo /D [5 0 R /Fit] /Next [21 0 R 22 0 R]>>")
            .Obj(21, "<</S /URI /URI (http://a)>>")
            .Obj(22, "<</S /URI /URI (http://b)>>"));

        PageOperations.Delete(document, [1]);

        Assert.False(Dict(document, 21).ContainsKey("Next"));
        foreach (int link in new[] { 90, 91 })
        {
            var action = Assert.IsType<PdfDictionary>(document.Resolve(Dict(document, link)["A"]));
            Assert.Equal("http://a", System.Text.Encoding.Latin1.GetString(((PdfString)action["URI"]!).Bytes));
            var rest = Assert.IsType<PdfArray>(document.Resolve(action["Next"]));
            Assert.Equal(new PdfReference(22, 0), Assert.Single(rest.Items));
        }
    }

    [Fact]
    public void ALiveLinkDoesNotGainTheFollowersOfADeadAction()
    {
        var document = PageTestFiles.Open(2, "/OpenAction 20 0 R", pageExtra: i => i == 0 ? "/Annots [90 0 R]" : "", add: pdf => pdf
            .Obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 21 0 R>>")
            .Obj(20, "<</S /GoTo /D [5 0 R /Fit] /Next [21 0 R 22 0 R]>>")
            .Obj(21, "<</S /URI /URI (http://a)>>")
            .Obj(22, "<</S /URI /URI (http://b)>>"));

        PageOperations.Delete(document, [1]);

        Assert.False(Dict(document, 21).ContainsKey("Next"));
    }

    [Theory]
    [InlineData("[21 0 R 21 0 R]", "")]
    [InlineData("[21 0 R 22 0 R]", "/Next 21 0 R")]
    public void FollowersMergedIntoOneActionNeverMakeALoop(string next, string back)
    {
        var document = PageTestFiles.Open(2, "/OpenAction 20 0 R", add: pdf => pdf
            .Obj(20, $"<</S /GoTo /D [5 0 R /Fit] /Next {next}>>")
            .Obj(21, "<</S /URI /URI (http://a)>>")
            .Obj(22, $"<</S /URI /URI (http://b) {back}>>"));

        PageOperations.Delete(document, [1]);

        Assert.False(Dict(document, 21).ContainsKey("Next"));
    }

    [Fact]
    public async Task ManyLinksSharingOneActionWithManyFollowersEnds()
    {
        const int Links = 20_000;
        var document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? $"/Annots [{string.Join(" ", Enumerable.Range(0, Links).Select(n => $"{1000 + n} 0 R"))}]" : "", add: pdf =>
        {
            pdf.Obj(20, $"<</S /URI /URI (http://a) /Next [{string.Join(" ", Enumerable.Range(0, Links).Select(n => $"{1000 + Links + n} 0 R"))}]>>");
            for (int n = 0; n < Links; n++)
            {
                pdf.Obj(1000 + n, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 20 0 R>>");
                pdf.Obj(1000 + Links + n, "<</S /URI /URI (http://b)>>");
            }
        });

        await Task.Run(() => PageOperations.Delete(document, [1])).WaitAsync(TimeSpan.FromSeconds(10));
    }

    [Fact]
    public async Task AThreadListedManyTimesIsWalkedOnce()
    {
        const int Beads = 20_000;
        int free = PageTestFiles.Free(2);
        var document = PageTestFiles.Open(2, $"/Threads [{string.Join(" ", Enumerable.Repeat($"{free} 0 R", Beads))}]", add: pdf =>
        {
            pdf.Obj(free, $"<</Type /Thread /F {free + 1} 0 R>>");
            for (int i = 0; i < Beads; i++)
            {
                int next = free + 1 + (i + 1) % Beads, previous = free + 1 + (i + Beads - 1) % Beads;
                pdf.Obj(free + 1 + i, $"<</Type /Bead /N {next} 0 R /V {previous} 0 R /P {(i == 0 ? 5 : 4)} 0 R /R [0 0 1 1]>>");
            }
        });

        await Task.Run(() => PageOperations.Delete(document, [1])).WaitAsync(TimeSpan.FromSeconds(10));

        var thread = (PdfDictionary)document.Get(free)!;
        Assert.Equal(new PdfReference(free + 2, 0), thread["F"]);
    }

    [Fact]
    public void TwoThreadsOnTheSameBeadsBothGoWithThem()
    {
        int free = PageTestFiles.Free(2);
        var document = PageTestFiles.Open(2, $"/Threads [{free} 0 R {free + 1} 0 R]", add: pdf => pdf
            .Obj(free, $"<</Type /Thread /F {free + 2} 0 R>>")
            .Obj(free + 1, $"<</Type /Thread /F {free + 2} 0 R>>")
            .Obj(free + 2, $"<</Type /Bead /N {free + 3} 0 R /V {free + 3} 0 R /P 5 0 R /R [0 0 1 1]>>")
            .Obj(free + 3, $"<</Type /Bead /N {free + 2} 0 R /V {free + 2} 0 R /P 5 0 R /R [0 0 1 1]>>"));

        PageOperations.Delete(document, [1]);

        Assert.Empty(document.Array(document.Catalog, "Threads")!.Items);
    }
}
