using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageActionWalkTests
{
    private static PdfDictionary Dict(PdfDocument document, int number) => Assert.IsType<PdfDictionary>(document.Get(number));

    [Fact]
    public void LinksWithTheirOwnActionsShareOneFollowerArray()
    {
        var document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? "/Annots [90 0 R 91 0 R]" : "", add: pdf => pdf
            .Obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 30 0 R>>")
            .Obj(91, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 31 0 R>>")
            .Obj(30, "<</S /URI /URI (http://a) /Next 20 0 R>>")
            .Obj(31, "<</S /URI /URI (http://b) /Next 20 0 R>>")
            .Obj(20, "[21 0 R 22 0 R]")
            .Obj(21, "<</S /GoTo /D [5 0 R /Fit]>>")
            .Obj(22, "<</S /URI /URI (http://c)>>"));

        PageOperations.Delete(document, [1]);

        var first = document.Resolve(Dict(document, 30)["Next"]);
        var second = document.Resolve(Dict(document, 31)["Next"]);
        Assert.Same(first, second);
        Assert.Equal(new PdfReference(22, 0), Assert.Single(Assert.IsType<PdfArray>(first).Items));
    }

    [Fact]
    public void AnArrayOfLiveActionsIsLeftAsItIs()
    {
        var document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? "/Annots [90 0 R]" : "", add: pdf => pdf
            .Obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 30 0 R>>")
            .Obj(30, "<</S /URI /URI (http://a) /Next 20 0 R>>")
            .Obj(20, "[21 0 R 22 0 R]")
            .Obj(21, "<</S /URI /URI (http://b)>>")
            .Obj(22, "<</S /URI /URI (http://c)>>"));

        PageOperations.Delete(document, [1]);

        Assert.Equal(new PdfReference(20, 0), Dict(document, 30)["Next"]);
    }

    [Fact]
    public void AnActionCutShortAtTheDepthLimitIsWalkedAgainFromALiveLink()
    {
        var document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? "/Annots [90 0 R 91 0 R]" : "", add: pdf =>
        {
            pdf.Obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 100 0 R>>");
            pdf.Obj(91, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 132 0 R>>");
            for (int i = 0; i < 32; i++) pdf.Obj(100 + i, $"<</S /URI /URI (http://a) /Next {101 + i} 0 R>>");
            pdf.Obj(132, "<</S /URI /URI (http://x) /Next 133 0 R>>");
            pdf.Obj(133, "<</S /GoTo /D [5 0 R /Fit]>>");
        });

        PageOperations.Delete(document, [1]);

        Assert.False(Dict(document, 132).ContainsKey("Next"));
    }

    [Fact]
    public void LinksWhoseGoToIsDroppedShareOneLead()
    {
        const int links = 300;
        var document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? "/Annots [" + string.Join(" ", Enumerable.Range(0, links).Select(n => $"{1000 + n} 0 R")) + "]" : "", add: pdf =>
        {
            for (int n = 0; n < links; n++)
            {
                pdf.Obj(1000 + n, $"<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A {2000 + n} 0 R>>");
                pdf.Obj(2000 + n, "<</S /GoTo /D [5 0 R /Fit] /Next 20 0 R>>");
            }
            pdf.Obj(20, "[21 0 R 22 0 R 23 0 R]");
            for (int n = 21; n <= 23; n++) pdf.Obj(n, "<</S /URI /URI (http://a)>>");
        });

        PageOperations.Delete(document, [1]);

        var first = Assert.IsType<PdfReference>(Dict(document, 1000)["A"]);
        Assert.Equal(first, Dict(document, 1000 + links - 1)["A"]);
        Assert.Equal(2, Assert.IsType<PdfArray>(document.Resolve(Dict(document, first.Number)["Next"])).Items.Count);
    }

    [Fact]
    public void ADroppedMemberLeavesTheSharedArrayInPlaceForEveryHolder()
    {
        const int links = 200;
        var document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? "/Annots [" + string.Join(" ", Enumerable.Range(0, links).Select(n => $"{1000 + n} 0 R")) + "]" : "", add: pdf =>
        {
            for (int n = 0; n < links; n++)
            {
                pdf.Obj(1000 + n, $"<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A {2000 + n} 0 R>>");
                pdf.Obj(2000 + n, "<</S /URI /URI (http://a) /Next 20 0 R>>");
                pdf.Obj(3000 + n, n == 0 ? "<</S /GoTo /D [5 0 R /Fit]>>" : "<</S /URI /URI (http://b)>>");
            }
            pdf.Obj(20, "[" + string.Join(" ", Enumerable.Range(0, links).Select(n => $"{3000 + n} 0 R")) + "]");
        });

        PageOperations.Delete(document, [1]);

        for (int n = 0; n < links; n++) Assert.Equal(new PdfReference(20, 0), Dict(document, 2000 + n)["Next"]);
        Assert.Equal(links - 1, Assert.IsType<PdfArray>(document.Get(20)).Items.Count);
    }

    [Theory]
    [InlineData("[21 0 R 22 0 R]")]
    [InlineData("[21 0 R 21 0 R]")]
    public void AnArrayWhoseMembersAreMetThroughAnotherHolderIsLeftAsItIs(string array)
    {
        var document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? "/Annots [89 0 R 90 0 R]" : "", add: pdf => pdf
            .Obj(89, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 21 0 R>>")
            .Obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 30 0 R>>")
            .Obj(30, "<</S /URI /URI (http://a) /Next 20 0 R>>")
            .Obj(20, array)
            .Obj(21, "<</S /URI /URI (http://b)>>")
            .Obj(22, "<</S /URI /URI (http://c)>>"));

        PageOperations.Delete(document, [1]);

        Assert.Equal(new PdfReference(20, 0), Dict(document, 30)["Next"]);
        Assert.Equal(2, Assert.IsType<PdfArray>(document.Get(20)).Items.Count);
    }

    [Fact]
    public void AnArrayCutShortAtTheDepthLimitIsWalkedAgainFromALiveLink()
    {
        var document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? "/Annots [90 0 R 91 0 R]" : "", add: pdf =>
        {
            pdf.Obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 100 0 R>>");
            pdf.Obj(91, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 200 0 R>>");
            for (int i = 0; i < 31; i++) pdf.Obj(100 + i, $"<</S /URI /URI (http://a) /Next {101 + i} 0 R>>");
            pdf.Obj(131, "<</S /URI /URI (http://a) /Next 20 0 R>>");
            pdf.Obj(200, "<</S /URI /URI (http://z) /Next 20 0 R>>");
            pdf.Obj(20, "[132 0 R]");
            pdf.Obj(132, "<</S /URI /URI (http://x) /Next 133 0 R>>");
            pdf.Obj(133, "<</S /GoTo /D [5 0 R /Fit]>>");
        });

        PageOperations.Delete(document, [1]);

        Assert.False(Dict(document, 132).ContainsKey("Next"));
    }

    [Theory]
    [InlineData("90 0 R 91 0 R")]
    [InlineData("91 0 R 90 0 R")]
    public void AnActionThatLoopsBackToADroppedGoToDoesNotKeepIt(string annots)
    {
        var document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? $"/Annots [{annots}]" : "", add: pdf => pdf
            .Obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 30 0 R>>")
            .Obj(91, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 32 0 R>>")
            .Obj(30, "<</S /GoTo /D [5 0 R /Fit] /Next 31 0 R>>")
            .Obj(31, "<</S /URI /URI (http://u) /Next 30 0 R>>")
            .Obj(32, "<</S /URI /URI (http://w) /Next 31 0 R>>"));

        PageOperations.Delete(document, [1]);

        Assert.NotEqual<PdfObject?>(new PdfReference(30, 0), Dict(document, 31)["Next"]);
        Assert.NotEqual<PdfObject?>(new PdfReference(30, 0), Dict(document, 90)["A"]);
    }
}
