using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageCleanupReviewTests
{
    [Fact]
    public void ANewPageAtTheStartHasANumberedLabel()
    {
        var document = PageTestFiles.Open(3, "/PageLabels <</Nums [0 <</S /r>>]>>");
        PageOperations.InsertBlank(document, 0, 100, 100);
        var first = document.Array(document.Dict(document.Catalog, "PageLabels"), "Nums")!.Items;
        Assert.Equal("D", document.Name((PdfDictionary)document.Resolve(first[1])!, "S"));
    }

    [Fact]
    public void NameTreeLimitsFollowTheKeysThatRemain()
    {
        int free = PageTestFiles.Free(3);
        var document = PageTestFiles.Open(3, $"/Names <</Dests <</Kids [{free} 0 R {free + 1} 0 R]>>>>", add: pdf => pdf
            .Obj(free, "<</Limits [(a) (m)] /Names [(a) [4 0 R /Fit] (m) [5 0 R /Fit]]>>")
            .Obj(free + 1, "<</Limits [(n) (z)] /Names [(n) [6 0 R /Fit] (z) [6 0 R /Fit]]>>"));
        PageOperations.Delete(document, [0, 2]);
        var root = document.Dict(document.Dict(document.Catalog, "Names"), "Dests")!;
        Assert.Equal(["m"], PdfNameTree.Read(document, root).Select(e => e.Key));
        Assert.False(root.ContainsKey("Limits"));
    }

    [Fact]
    public void ThreadBeadsOnDeletedPagesLeaveTheirArticle()
    {
        int free = PageTestFiles.Free(3);
        var document = PageTestFiles.Open(3, $"/Threads [{free} 0 R]", add: pdf => pdf
            .Obj(free, $"<</Type /Thread /F {free + 1} 0 R>>")
            .Obj(free + 1, $"<</Type /Bead /T {free} 0 R /N {free + 2} 0 R /V {free + 2} 0 R /P 4 0 R /R [0 0 10 10]>>")
            .Obj(free + 2, $"<</Type /Bead /N {free + 1} 0 R /V {free + 1} 0 R /P 5 0 R /R [0 0 10 10]>>"));
        PageOperations.Delete(document, [0]);
        var thread = (PdfDictionary)document.Resolve(document.Array(document.Catalog, "Threads")!.Items[0])!;
        var bead = (PdfDictionary)document.Resolve(thread["F"])!;
        Assert.Equal(document.Pages[0].Reference, bead["P"]);
        Assert.Equal(thread["F"], bead["N"]);
    }

    [Fact]
    public void AGoToChainedAfterAnotherActionLosesItsDeadDestination()
    {
        int free = PageTestFiles.Free(3);
        var document = PageTestFiles.Open(3, $"/Outlines {free} 0 R", add: pdf => pdf
            .Obj(free, $"<</Type /Outlines /First {free + 1} 0 R /Last {free + 1} 0 R /Count 1>>")
            .Obj(free + 1, $"<</Title (x) /Parent {free} 0 R /A <</S /URI /URI (http://x) /Next <</S /GoTo /D [5 0 R /Fit]>>>>>>"));
        PageOperations.Delete(document, [1]);
        var action = (PdfDictionary)document.Get(free + 1)!;
        Assert.Null(document.Dict(document.Dict(action, "A"), "Next"));
    }

    [Fact]
    public void RemovingARadioButtonTakesItsOptionAndState()
    {
        int free = PageTestFiles.Free(2);
        var document = PageTestFiles.Open(2, $"/AcroForm <</Fields [{free} 0 R]>>", i => $"/Annots [{free + 1 + i} 0 R]", add: pdf => pdf
            .Obj(free, $"<</FT /Btn /Ff 49152 /T (r) /V /a /Opt [(A) (B)] /Kids [{free + 1} 0 R {free + 2} 0 R]>>")
            .Obj(free + 1, $"<</Type /Annot /Subtype /Widget /Parent {free} 0 R /Rect [0 0 10 10] /AS /a /AP <</N <</a {free + 3} 0 R /Off {free + 3} 0 R>>>>>>")
            .Obj(free + 2, $"<</Type /Annot /Subtype /Widget /Parent {free} 0 R /Rect [20 0 30 10] /AS /Off /AP <</N <</b {free + 3} 0 R /Off {free + 3} 0 R>>>>>>")
            .Stream(free + 3, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", ""));
        PageOperations.Delete(document, [0]);
        var field = (PdfDictionary)document.Get(free)!;
        Assert.Equal(["B"], document.Array(field, "Opt")!.Items.Select(i => PdfText.Read(document, i)));
        Assert.Equal("Off", document.Name(field, "V"));
    }
}
