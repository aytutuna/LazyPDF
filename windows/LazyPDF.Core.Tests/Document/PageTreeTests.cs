using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageTreeTests
{
    private static PdfDocument Open(TestPdf pdf) => PdfDocument.Open(pdf.Finish());

    [Fact]
    public void PagesComeInReadingOrderWithTheirReferences()
    {
        var document = PdfDocument.Open(TestPdf.Simple(3));
        Assert.Equal(3, document.Pages.Count);
        Assert.Equal([0, 1, 2], document.Pages.Select(p => p.Index).ToArray());
        Assert.Equal([3, 4, 5], document.Pages.Select(p => p.Reference.Number).ToArray());
        Assert.Same(document.Get(4), document.Pages[1].Dictionary);
        Assert.Equal("BT /F1 12 Tf (2) Tj ET", TestPdf.Text(document.Pages[1].Contents()));
    }

    [Fact]
    public void PagesTakeWhatTheirAncestorsSet()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 2 /MediaBox [0 0 100 200] /Rotate 90 /Resources <</Font <<>>>>>>")
            .Obj(3, "<</Type /Pages /Parent 2 0 R /Kids [4 0 R 5 0 R] /Count 2 /CropBox [10 10 60 60]>>")
            .Obj(4, "<</Type /Page /Parent 3 0 R>>")
            .Obj(5, "<</Type /Page /Parent 3 0 R /Rotate 270 /MediaBox [0 0 50 50] /Resources <</XObject <<>>>>>>");
        var document = Open(pdf);
        var first = document.Pages[0];
        Assert.Equal(new PdfRect(0, 0, 100, 200), first.MediaBox);
        Assert.Equal(new PdfRect(10, 10, 60, 60), first.CropBox);
        Assert.Equal(90, first.Rotate);
        Assert.True(first.Resources!.ContainsKey("Font"));
        var second = document.Pages[1];
        Assert.Equal(270, second.Rotate);
        Assert.True(second.Resources!.ContainsKey("XObject"));
        Assert.Equal(new PdfRect(10, 10, 50, 50), second.CropBox);
    }

    [Fact]
    public void BoxesAreNormalizedAndDefaulted()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>")
            .Obj(3, "<</Type /Page /MediaBox [300 400 0 0] /TrimBox [5 5 15 25] /Rotate 450 /UserUnit 2>>")
            .Obj(4, "<</Type /Page /MediaBox [0 0 0 0] /CropBox [1 2] /Rotate -90 /UserUnit -3 /BleedBox (x)>>");
        var document = Open(pdf);
        var page = document.Pages[0];
        Assert.Equal(new PdfRect(0, 0, 300, 400), page.MediaBox);
        Assert.Equal(300, page.CropBox.Right);
        Assert.Equal(new PdfRect(5, 5, 15, 25), page.TrimBox);
        Assert.Equal(page.CropBox, page.ArtBox);
        Assert.Equal(90, page.Rotate);
        Assert.Equal(2, page.UserUnit);
        var junk = document.Pages[1];
        Assert.Equal(new PdfRect(0, 0, 612, 792), junk.MediaBox);
        Assert.Equal(junk.MediaBox, junk.CropBox);
        Assert.Equal(junk.MediaBox, junk.BleedBox);
        Assert.Equal(270, junk.Rotate);
        Assert.Equal(1, junk.UserUnit);
    }

    [Fact]
    public void ACycleCostsOnlyTheEntryThatLoops()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R 2 0 R 4 0 R] /Count 2>>")
            .Obj(3, "<</Type /Page /Parent 2 0 R>>")
            .Obj(4, "<</Type /Pages /Parent 2 0 R /Kids [2 0 R 5 0 R]>>")
            .Obj(5, "<</Type /Page /Parent 4 0 R>>");
        var document = Open(pdf);
        Assert.Equal([3, 5], document.Pages.Select(p => p.Reference.Number).ToArray());
        Assert.Contains(document.Repairs, r => r.Contains("loop"));
    }

    [Fact]
    public void WrongCountIsNoted()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 40>>")
            .Obj(3, "<</Type /Page>>");
        var document = Open(pdf);
        Assert.Single(document.Pages);
        Assert.Contains(document.Repairs, r => r.Contains("40 pages"));
    }

    [Fact]
    public void MissingTypesAndParentsAreTolerated()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Pages 2 0 R>>")
            .Obj(2, "<</Kids [3 0 R 4 0 R]>>")
            .Obj(3, "<</Contents 9 0 R /MediaBox [0 0 5 5]>>")
            .Obj(4, "<</Kids [5 0 R]>>")
            .Obj(5, "<</Resources <<>>>>");
        var document = Open(pdf);
        Assert.Equal(2, document.Pages.Count);
        Assert.Equal(5, document.Pages[0].MediaBox.Width);
    }

    [Fact]
    public void JunkInKidsIsSkipped()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R 42 (text) null 77 0 R 6 0 R <</Type /Page>> 5 0 R 3 0 R] /Count 2>>")
            .Obj(3, "<</Type /Page>>")
            .Obj(5, "<</Type /Font /BaseFont /Helvetica>>")
            .Obj(6, "[1 2 3]");
        var document = Open(pdf);
        Assert.Single(document.Pages);
        Assert.Contains(document.Repairs, r => r.Contains("not pages"));
    }

    [Fact]
    public void ATreeThatHoldsNothingFallsBackToThePagesInTheFile()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids 3 0 R>>")
            .Obj(3, "<</Type /Page>>");
        var document = Open(pdf);
        Assert.Single(document.Pages);
        Assert.Contains(document.Repairs, r => r.Contains("found by scanning"));
    }

    [Fact]
    public void ADeepTreeIsStoppedAtTheCap()
    {
        var pdf = new TestPdf().Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        for (int i = 2; i < 400; i++) pdf.Obj(i, $"<</Type /Pages /Kids [{i + 1} 0 R]>>");
        pdf.Obj(400, "<</Type /Page>>");
        var document = Open(pdf);
        // Too deep to walk, so the page is found by scanning instead.
        Assert.Single(document.Pages);
        Assert.Contains(document.Repairs, r => r.Contains("scanning"));
    }

    [Fact]
    public void APageListedTwiceCountsOnce()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>")
            .Obj(3, "<</Type /Page>>")
            .Obj(4, "<</Type /Pages /Kids [3 0 R]>>");
        Assert.Single(Open(pdf).Pages);
    }

    [Fact]
    public void ContentStreamsAreJoinedAndBadOnesLeftOut()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3>>")
            .Obj(3, "<</Type /Page /Contents [6 0 R 77 0 R 7 0 R 8 0 R null 9 0 R]>>")
            .Obj(4, "<</Type /Page /Contents 6 0 R>>")
            .Obj(5, "<</Type /Page>>")
            .Stream(6, "", "q")
            .Stream(7, "", "Q")
            .Stream(8, "/Filter /JBIG2Decode", "not a content stream")
            .Obj(9, "(not a stream)");
        var document = Open(pdf);
        Assert.Equal("q\nQ", TestPdf.Text(document.Pages[0].Contents()));
        Assert.Contains(document.Repairs, r => r.Contains("Page 1: a content stream could not be read"));
        Assert.Equal("q", TestPdf.Text(document.Pages[1].Contents()));
        Assert.Empty(document.Pages[2].Contents());
    }

    [Fact]
    public void EditedTreeIsWalkedAgainOnRequest()
    {
        var document = PdfDocument.Open(TestPdf.Simple(3));
        Assert.Equal(3, document.Pages.Count);
        var kids = document.Array(document.Dict(document.Catalog, "Pages"), "Kids")!;
        kids.Items.RemoveAt(0);
        Assert.Equal(3, document.Pages.Count);
        document.RefreshPages();
        Assert.Equal(2, document.Pages.Count);
        kids.Items.Clear();
        document.RefreshPages();
        Assert.Empty(document.Pages);
    }
}
