using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageImportTests
{
    /// <summary>
    /// A source with a nested tree: the root gives /MediaBox and /Resources, a node gives /Rotate.
    /// Pages 4 and 5 share an image and a font, page 6 inherits everything; page 4 has a bead and a tag.
    /// </summary>
    internal static byte[] Source(string extra = "", string catalogExtra = "", Action<TestPdf>? add = null, string extra5 = "")
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 30 0 R /Threads [21 0 R] " + catalogExtra + ">>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 3 /MediaBox [0 0 300 400] /Resources <</Font <</F1 10 0 R>>>>>>")
            .Obj(3, "<</Type /Pages /Parent 2 0 R /Kids [4 0 R 5 0 R 6 0 R] /Count 3 /Rotate 90>>")
            .Obj(4, "<</Type /Page /Parent 3 0 R /Contents 7 0 R /B [20 0 R] /StructParents 0 /Resources <</Font <</F1 10 0 R>> /XObject <</Im1 11 0 R>>>> " + extra + ">>")
            .Obj(5, "<</Type /Page /Parent 3 0 R /Contents 8 0 R /Resources <</Font <</F1 10 0 R>> /XObject <</Im1 11 0 R>>>> " + extra5 + ">>")
            .Obj(6, "<</Type /Page /Parent 3 0 R /Contents 9 0 R>>")
            .Stream(7, "", "BT /F1 12 Tf (Page 11) Tj ET q /Im1 Do Q")
            .Stream(8, "", "BT /F1 12 Tf (Page 12) Tj ET q /Im1 Do Q")
            .Stream(9, "", "BT /F1 12 Tf (Page 13) Tj ET")
            .Obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>")
            .Stream(11, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", new byte[] { 0x80 })
            .Obj(20, "<</Type /Bead /P 4 0 R /T 21 0 R /N 20 0 R /V 20 0 R>>")
            .Obj(21, "<</Type /Thread /F 20 0 R>>")
            .Obj(30, "<</Type /StructTreeRoot /K 31 0 R>>")
            .Obj(31, "<</S /P /Pg 4 0 R /K 0>>");
        add?.Invoke(pdf);
        return pdf.Finish();
    }

    private static Dictionary<string, int> Types(PdfDocument document)
    {
        var counts = new Dictionary<string, int>();
        foreach (int number in document.ObjectNumbers)
        {
            var dictionary = document.Get(number) switch { PdfStream s => s.Dictionary, PdfDictionary d => d, _ => null };
            if (document.Name(dictionary, "Type") is { } type) counts[type] = counts.GetValueOrDefault(type) + 1;
            if (document.Name(dictionary, "Subtype") is "Image") counts["Image"] = counts.GetValueOrDefault("Image") + 1;
        }
        return counts;
    }

    [Fact]
    public void PagesComeInAtTheIndexInTheOrderAsked()
    {
        var target = PageTestFiles.Open(2);
        PageOperations.ImportPages(target, PdfDocument.Open(Source()), [2, 0], 1);
        Assert.Equal([1, 13, 11, 2], PageTestFiles.Order(target));
        Assert.Equal(["Page 1", "Page 13", "Page 11", "Page 2"], PageTestFiles.Reopen(target));
    }

    [Fact]
    public void AtTheEndAndAtTheStartAreFine()
    {
        var target = PageTestFiles.Open(1);
        var source = PdfDocument.Open(Source());
        PageOperations.ImportPages(target, source, [0], 1);
        PageOperations.ImportPages(target, source, [1], 0);
        Assert.Equal([12, 1, 11], PageTestFiles.Order(target));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageOperations.ImportPages(target, source, [0], 4));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageOperations.ImportPages(target, source, [3], 0));
        Assert.Equal(3, target.Pages.Count);
    }

    [Fact]
    public void AFontAndAnImageUsedByManyPagesAreCopiedOnce()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, PdfDocument.Open(Source()), [0, 1, 2], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        var types = Types(again);
        Assert.Equal(2, types["Font"]);
        Assert.Equal(1, types["Image"]);
    }

    [Fact]
    public void WhatAPageInheritsIsWrittenOntoIt()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, PdfDocument.Open(Source()), [2], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        var page = again.Pages[1];
        Assert.True(page.Dictionary.ContainsKey("MediaBox"));
        Assert.True(page.Dictionary.ContainsKey("Rotate"));
        Assert.Equal(new PdfRect(0, 0, 300, 400), page.MediaBox);
        Assert.Equal(90, page.Rotate);
        Assert.True(again.Dict(page.Dictionary, "Resources")!.ContainsKey("Font"));
        Assert.Equal(new PdfRect(0, 0, 200, 300), again.Pages[0].MediaBox);
        Assert.Equal(0, again.Pages[0].Rotate);
    }

    [Fact]
    public void TheSourcesTreeTagsAndThreadsStayBehind()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, PdfDocument.Open(Source()), [0, 1, 2], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        var types = Types(again);
        Assert.Equal(1, types["Pages"]);
        Assert.Equal(4, types["Page"]);
        Assert.False(types.ContainsKey("Bead"));
        Assert.False(types.ContainsKey("StructTreeRoot"));
        Assert.False(types.ContainsKey("Thread"));
        Assert.All(again.Pages, p => Assert.False(p.Dictionary.ContainsKey("StructParents") || p.Dictionary.ContainsKey("B")));
        Assert.All(again.Pages, p => Assert.Equal(again.Dict(again.Catalog, "Pages"), again.Dict(p.Dictionary, "Parent")));
    }

    [Fact]
    public void ThePagesCopiedStayIndependentOfTheSource()
    {
        var source = PdfDocument.Open(Source());
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, source, [0], 1);
        PageOperations.Rotate(target, [1], 90);
        source.Pages[0].Dictionary["Rotate"] = new PdfNumber(270L);
        Assert.Equal(180, target.Pages[1].Rotate);
        Assert.Equal(270, source.Pages[0].Rotate);
    }

    [Fact]
    public void ThePageIsRotatedTheWayItWas()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, PdfDocument.Open(Source()), [0], 1);
        Assert.Equal(90, target.Pages[1].Rotate);
        PageOperations.Rotate(target, [1], 90);
        Assert.Equal(180, target.Pages[1].Rotate);
    }

    [Fact]
    public void TheSamePageTwiceGivesTwoPagesThatShareTheirResources()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, PdfDocument.Open(Source()), [0, 0], 1);
        Assert.Equal([1, 11, 11], PageTestFiles.Order(target));
        var again = PdfDocument.Open(target.SaveRewrite());
        Assert.Equal(1, Types(again)["Image"]);
    }

    [Fact]
    public void ImportsIntoOneDocumentFromTheDocumentItselfShareEverything()
    {
        var target = PageTestFiles.Open(2);
        PageOperations.ImportPages(target, target, [1, 0], 2);
        Assert.Equal([1, 2, 2, 1], PageTestFiles.Order(target));
        Assert.Equal(1, Types(PdfDocument.Open(target.SaveRewrite()))["Font"]);
    }

    [Fact]
    public void ACommittedImportIsOneStepAndUndoesCleanly()
    {
        var session = PdfEditSession.Open(PageTestFiles.Make(2));
        PageOperations.ImportPages(session.Document, PdfDocument.Open(Source()), [0, 1], 2);
        var reopened = PageTestFiles.Commit(session, "Insert pages");
        Assert.Equal([1, 2, 11, 12], PageTestFiles.Order(reopened));
        Assert.True(session.Undo());
        Assert.Equal([1, 2], PageTestFiles.Order(session.Document));
    }
}
