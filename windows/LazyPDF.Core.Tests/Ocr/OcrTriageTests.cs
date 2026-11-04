using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OcrTriageTests
{
    private static OcrPageKind KindOf(PdfDocument document, int page = 0) => OcrTriage.Classify(document, document.Pages[page]);

    [Fact]
    public void KindsOfPages()
    {
        Assert.Equal(OcrPageKind.Picture, KindOf(OcrKit.Scan()));
        Assert.Equal(OcrPageKind.Blank, KindOf(OcrKit.Scan(1, "", "")));
        Assert.Equal(OcrPageKind.Drawing, KindOf(OcrKit.Scan(1, "", "0 0 100 100 re f")));
        Assert.Equal(OcrPageKind.Drawing, KindOf(OcrKit.Scan(1, "", "q 40 0 0 40 10 10 cm /Im1 Do Q")));
        Assert.Equal(OcrPageKind.Text, KindOf(OcrKit.Scan(1, "", "BT /F1 12 Tf 50 500 Td (Hello) Tj ET")));
        Assert.Equal(OcrPageKind.ForeignLayer, KindOf(OcrKit.Scan(1, "", "q 400 0 0 600 0 0 cm /Im1 Do Q BT 3 Tr /F1 12 Tf 50 500 Td (Hello) Tj ET")));
    }

    [Fact]
    public void PictureWithAStampOfTextIsStillAPictureButTextBeneathItIsText()
    {
        Assert.Equal(OcrPageKind.Picture, KindOf(OcrKit.Scan(1, "", "q 400 0 0 600 0 0 cm /Im1 Do Q BT /F1 8 Tf 10 10 Td (B 000123) Tj ET")));
        string lines = string.Concat(Enumerable.Range(0, 30).Select(i => $"BT /F1 14 Tf 20 {550 - 18 * i} Td (A line of printed words that fills the page) Tj ET "));
        Assert.Equal(OcrPageKind.Text, KindOf(OcrKit.Scan(1, "", "q 400 0 0 600 0 0 cm /Im1 Do Q " + lines)));
    }

    [Fact]
    public void PictureShareIsOfTheCropBox()
    {
        var document = OcrKit.Scan(1, "/CropBox [0 0 200 300]", "q 200 0 0 300 0 0 cm /Im1 Do Q");
        Assert.Equal(OcrPageKind.Picture, KindOf(document));
        var half = OcrKit.Scan(1, "", "q 400 0 0 200 0 0 cm /Im1 Do Q");
        Assert.Equal(OcrPageKind.Drawing, KindOf(half));
    }

    [Fact]
    public void InvisibleTextOfOtherToolsAndHiddenModesAreNotVisibleText()
    {
        Assert.Equal(OcrPageKind.Blank, KindOf(OcrKit.Scan(1, "", "BT 7 Tr /F1 12 Tf 50 500 Td (Clip) Tj ET")));
        Assert.Equal(OcrPageKind.Blank, KindOf(OcrKit.Scan(1, "", "BT /F1 12 Tf 50 500 Td (   ) Tj ET")));
    }

    [Fact]
    public void OurOwnLayerIsRecognizedWhateverElseThePageShows()
    {
        var scan = OcrKit.Scan();
        PdfOcrLayer.Add(scan, [new OcrPageWords(0, OcrKit.Words(), 400, 600)], "en");
        Assert.Equal(OcrPageKind.OwnLayer, KindOf(scan));
        PdfOcrLayer.Remove(scan, scan.Pages[0]);
        Assert.Equal(OcrPageKind.Picture, KindOf(scan));

        var printed = OcrKit.Scan(1, "", "BT /F1 12 Tf 50 500 Td (Hello) Tj ET");
        PdfOcrLayer.Add(printed, [new OcrPageWords(0, OcrKit.Words(), 400, 600)], "en");
        Assert.Equal(OcrPageKind.OwnLayer, KindOf(printed));
    }

    [Fact]
    public void ClassifyAllGivesOneKindPerPage()
    {
        var document = OcrKit.Pages("BT /F1 12 Tf 50 500 Td (Hello) Tj ET", "", "0 0 10 10 re f");
        Assert.Equal([OcrPageKind.Text, OcrPageKind.Blank, OcrPageKind.Drawing], OcrTriage.ClassifyAll(document));
    }

    [Theory]
    [InlineData(OcrPageKind.Picture, false, false, true)]
    [InlineData(OcrPageKind.Drawing, false, false, true)]
    [InlineData(OcrPageKind.OwnLayer, false, false, false)]
    [InlineData(OcrPageKind.OwnLayer, true, false, true)]
    [InlineData(OcrPageKind.Text, true, false, false)]
    [InlineData(OcrPageKind.Text, false, true, true)]
    [InlineData(OcrPageKind.ForeignLayer, true, false, false)]
    [InlineData(OcrPageKind.ForeignLayer, false, true, true)]
    [InlineData(OcrPageKind.Blank, true, false, false)]
    public void NeedsOcr(OcrPageKind kind, bool replace, bool force, bool expected) =>
        Assert.Equal(expected, OcrTriage.NeedsOcr(kind, replace, force));

    [Fact]
    public void PageThatCannotBeInterpretedDoesNotThrow()
    {
        var document = OcrKit.Scan(1, "", "q q q BT BT ET ET Q Q Q Q Q /Nope Do /F9 12 Tf (x) Tj [ ( ) ");
        var kind = KindOf(document);
        Assert.True(Enum.IsDefined(kind));
    }
}
