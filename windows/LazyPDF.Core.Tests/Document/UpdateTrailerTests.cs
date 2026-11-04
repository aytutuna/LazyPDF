using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class UpdateTrailerTests
{
    [Theory]
    [InlineData("table")]
    [InlineData("stream")]
    [InlineData("hybrid")]
    public void AnInfoTakenOutStaysOutAfterAReopen(string kind)
    {
        var document = PdfDocument.Open(SaveFixtures.Make(kind));
        Assert.NotNull(document.Info);
        document.Trailer.Remove("Info");
        var reopened = PdfDocument.Open(document.SaveIncremental());
        Assert.Null(reopened.Info);

        reopened.Catalog["Touched"] = new PdfNumber(1);
        Assert.Null(PdfDocument.Open(reopened.SaveIncremental()).Info);
    }

    [Fact]
    public void ASizeBeyondTheNumberLimitIsNotTakenAtItsWord()
    {
        byte[] file = SaveFixtures.Make("stream");
        byte[] huge = TestPdf.Replace(file, "/Size 9 ", "/Size 9999999 /Index [0 9] ");
        var document = PdfDocument.Open(huge);
        Assert.False(document.XrefRebuilt);
        Assert.True(document.NextObjectNumber <= 10);
        document.Info!["Author"] = new PdfString(TestPdf.Latin("Me"), isHex: false);
        Assert.False(PdfDocument.Open(document.SaveIncremental()).XrefRebuilt);
        document.Add(new PdfDictionary());
    }
}
