using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageBoxTests
{
    [Fact]
    public void BoxesAreSetOnTheChosenPagesOnly()
    {
        var document = PageTestFiles.Open(2);
        PageOperations.SetBox(document, [1], PageBox.Crop, new PdfRect(10, 20, 110, 220));
        PageOperations.SetBox(document, [0, 1], PageBox.Trim, new PdfRect(20, 30, 100, 200));
        PageOperations.SetBox(document, [0], PageBox.Bleed, new PdfRect(5, 5, 195, 295));
        PageOperations.SetBox(document, [1], PageBox.Art, new PdfRect(30, 40, 90, 100));
        Assert.Equal(new PdfRect(0, 0, 200, 300), document.Pages[0].CropBox);
        Assert.Equal(new PdfRect(10, 20, 110, 220), document.Pages[1].CropBox);
        Assert.Equal(new PdfRect(20, 30, 100, 200), document.Pages[0].TrimBox);
        Assert.Equal(new PdfRect(5, 5, 195, 295), document.Pages[0].BleedBox);
        Assert.Equal(new PdfRect(30, 40, 90, 100), document.Pages[1].ArtBox);
    }

    [Fact]
    public void MediaBoxReplacesWhatTheTreeGave()
    {
        var document = PageTestFiles.Open(2);
        PageOperations.SetBox(document, [0], PageBox.Media, new PdfRect(0, 0, 400, 500));
        Assert.Equal(new PdfRect(0, 0, 400, 500), document.Pages[0].MediaBox);
        Assert.Equal(new PdfRect(0, 0, 200, 300), document.Pages[1].MediaBox);
    }

    [Fact]
    public void ABoxIsClippedToThePaperAndRefusedWhenItMissesIt()
    {
        var document = PageTestFiles.Open(1);
        PageOperations.SetBox(document, [0], PageBox.Crop, new PdfRect(100, 100, 500, 500));
        Assert.Equal(new PdfRect(100, 100, 200, 300), document.Pages[0].CropBox);
        Assert.Equal(new PdfRect(100, 100, 200, 300), document.Rect(document.Pages[0].Dictionary["CropBox"]));
        Assert.Throws<ArgumentException>(() => PageOperations.SetBox(document, [0], PageBox.Art, new PdfRect(400, 400, 500, 500)));
        Assert.Throws<ArgumentException>(() => PageOperations.SetBox(document, [0], PageBox.Trim, new PdfRect(10, 10, 10, 50)));
    }

    [Fact]
    public void NullRemovesABoxExceptTheMediaBox()
    {
        var document = PageTestFiles.Open(1, pageExtra: _ => "/CropBox [10 10 50 50] /TrimBox [10 10 50 50]");
        PageOperations.SetBox(document, [0], PageBox.Crop, null);
        PageOperations.SetBox(document, [0], PageBox.Trim, null);
        Assert.False(document.Pages[0].Dictionary.ContainsKey("CropBox"));
        Assert.Equal(new PdfRect(0, 0, 200, 300), document.Pages[0].TrimBox);
        Assert.Throws<ArgumentException>(() => PageOperations.SetBox(document, [0], PageBox.Media, null));
    }

    [Fact]
    public void ChangingTheBoxKeepsTheContentAndMovesNothing()
    {
        var document = PageTestFiles.Open(1, pageExtra: _ => "/TrimBox [10 10 50 50]");
        PageOperations.Resize(document, [0], 100, 150, ResizeMode.ChangeBox);
        var page = document.Pages[0];
        Assert.Equal(new PdfRect(0, 0, 100, 150), page.MediaBox);
        Assert.Equal(page.MediaBox, page.CropBox);
        Assert.False(page.Dictionary.ContainsKey("TrimBox"));
        Assert.Equal("BT /F1 12 Tf 20 100 Td (Page 1) Tj ET", Encoding.Latin1.GetString(page.Contents()));
    }

    [Fact]
    public void ScalingWrapsTheContentInAMatrixThatFitsAndCentres()
    {
        var document = PageTestFiles.Open(1, pageExtra: _ => "/TrimBox [0 0 100 150] /Annots [<</Type /Annot /Subtype /Square /Rect [20 30 40 60]>>]");
        PageOperations.Resize(document, [0], 400, 300, ResizeMode.ScaleContent);
        var page = document.Pages[0];
        Assert.Equal(new PdfRect(0, 0, 400, 300), page.MediaBox);
        Assert.Equal(new PdfRect(0, 0, 400, 300), page.CropBox);
        // 200 x 300 into 400 x 300: scale 1, 100 to each side.
        string content = Encoding.Latin1.GetString(page.Contents());
        Assert.Equal("q 1 0 0 1 100 0 cm\n\nBT /F1 12 Tf 20 100 Td (Page 1) Tj ET\n\nQ", content);
        Assert.Equal(new PdfRect(100, 0, 200, 150), page.TrimBox);
        var annotation = (PdfDictionary)document.Array(page.Dictionary, "Annots")!.Items[0];
        Assert.Equal(new PdfRect(120, 30, 140, 60), document.Rect(annotation["Rect"]));
    }

    [Fact]
    public void ScalingDownKeepsTheAspectRatio()
    {
        var document = PageTestFiles.Open(1);
        PageOperations.Resize(document, [0], 100, 300, ResizeMode.ScaleContent);
        string content = Encoding.Latin1.GetString(document.Pages[0].Contents());
        Assert.StartsWith("q 0.5 0 0 0.5 0 75 cm", content);
    }

    [Fact]
    public void ATurnedPageIsSizedAsItIsShown()
    {
        var document = PageTestFiles.Open(1, pageExtra: _ => "/Rotate 90");
        PageOperations.Resize(document, [0], 400, 100, ResizeMode.ChangeBox);
        var page = document.Pages[0];
        Assert.Equal(new PdfRect(0, 0, 100, 400), page.MediaBox);
        var shown = new PageGeometry(page);
        Assert.Equal(400, shown.Width, 6);
        Assert.Equal(100, shown.Height, 6);
    }

    [Theory]
    [InlineData(0, 100)]
    [InlineData(100, -1)]
    [InlineData(20000, 100)]
    public void ASizeThatCannotBeAPageIsRefused(double width, double height)
    {
        var document = PageTestFiles.Open(1);
        Assert.Throws<ArgumentOutOfRangeException>(() => PageOperations.Resize(document, [0], width, height, ResizeMode.ChangeBox));
    }

    [Fact]
    public void TransitionsAndAdvanceTimesAreRemoved()
    {
        var document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? "/Trans <</S /Wipe>> /Dur 5" : "");
        PageOperations.RemoveTransitions(document, [0, 1]);
        Assert.All(document.Pages, p => Assert.False(p.Dictionary.ContainsKey("Trans") || p.Dictionary.ContainsKey("Dur")));
    }

    [Fact]
    public void RemovingABoxKeepsPagesThatWereFoundByScanning()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0>>");
        pdf.Obj(3, "<</Type /Page /MediaBox [0 0 200 300] /CropBox [10 10 50 50]>>");
        pdf.Obj(4, "<</Type /Page /MediaBox [0 0 200 300]>>");
        var document = PdfDocument.Open(pdf.Finish("/Root 1 0 R"));
        Assert.Equal(2, document.Pages.Count);
        PageOperations.SetBox(document, [0], PageBox.Crop, null);
        Assert.Equal(2, document.Pages.Count);
        Assert.Equal(new PdfRect(0, 0, 200, 300), document.Pages[0].CropBox);
        PageOperations.Rotate(document, [1], 90);
        Assert.Equal(90, document.Pages[1].Rotate);
    }
}
