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
}
