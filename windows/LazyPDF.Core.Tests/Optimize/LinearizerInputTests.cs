using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class LinearizerInputTests
{
    [Theory]
    [InlineData("table")]
    [InlineData("stream")]
    [InlineData("hybrid")]
    [InlineData("objects")]
    [InlineData("aes128")]
    [InlineData("aes256objects")]
    public void EveryLayoutOfSourceFileLinearizes(string kind)
    {
        using var source = PdfDocument.Open(SaveFixtures.Make(kind));
        byte[] file = source.SaveLinearized(new PdfSaveOptions(Security: source.Security));

        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        Assert.Equal(SaveFixtures.PageTwo, Encoding.Latin1.GetString(again.Pages[1].Contents()));
        Assert.Equal(source.IsEncrypted, again.IsEncrypted);
    }

    [Fact]
    public void ObjectStreamsAreNotUsed()
    {
        using var source = PdfDocument.Open(SaveFixtures.Make("objects"));
        byte[] file = source.SaveLinearized(new PdfSaveOptions(UseObjectStreams: true));

        string text = Encoding.Latin1.GetString(file);
        Assert.DoesNotContain("/ObjStm", text);
        Assert.DoesNotContain("/XRef", text);
        LinearizerKit.Verify(file);
    }

    [Fact]
    public void ARepairedFileLinearizes()
    {
        byte[] damaged = LinearizerKit.Make(6)[..^60];
        using var source = PdfDocument.Open(damaged);
        Assert.NotEmpty(source.Repairs);

        byte[] file = source.SaveLinearized();
        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        Assert.Empty(again.Repairs);
        Assert.Equal(6, again.Pages.Count);
    }

    [Fact]
    public void ReferencesToNothingAreDropped()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Names 77 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 88 0 R] /Count 2>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 50 50] /Contents [4 0 R 99 0 R] /Annots [66 0 R]>>");
        pdf.Stream(4, "", "0 0 m");
        byte[] file = PdfDocument.Open(pdf.Finish()).SaveLinearized();

        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        Assert.Single(again.Pages);
    }

    [Fact]
    public void AStreamWithAWrongLengthIsStoredWithTheLengthItHas()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 50 50]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R>>");
        pdf.Stream(4, "", "0 0 m 10 10 l S", length: 3);
        byte[] file = PdfDocument.Open(pdf.Finish()).SaveLinearized();

        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        Assert.Equal("0 0 m 10 10 l S", Encoding.Latin1.GetString(again.Pages[0].Contents()));
        Assert.Empty(again.Repairs);
    }

    [Fact]
    public void StreamDataIsCopiedAsItIs()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 50 50]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</XObject <</Im 5 0 R>>>>>>");
        pdf.Stream(4, "", "q /Im Do Q");
        pdf.Stream(5, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /Filter /FlateDecode /BitsPerComponent 8", new byte[] { 1, 2, 3, 4, 5 });
        byte[] file = PdfDocument.Open(pdf.Finish()).SaveLinearized();

        using var again = PdfDocument.Open(file);
        var image = again.Resolve<PdfStream>(again.Dict(again.Pages[0].Resources, "XObject")!["Im"])!;
        Assert.Equal(new byte[] { 1, 2, 3, 4, 5 }, again.RawData(image));
        LinearizerKit.Verify(file);
    }

    [Fact]
    public void AnIntegerBeyondSixtyFourBitsIsWrittenAsAReal()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 50 50]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Big 340282346638528859811704183484516925440 /Small 12>>");
        byte[] file = PdfDocument.Open(pdf.Finish()).SaveLinearized();

        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        var page = again.Pages[0].Dictionary;
        Assert.Equal("340282346638528859811704183484516925440.0", ((PdfNumber)page["Big"]!).Text);
        Assert.Equal("12", ((PdfNumber)page["Small"]!).Text);
    }

    [Fact]
    public void ALoopInTheParentChainEnds()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 50 50] /Parent 2 0 R>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        byte[] file = PdfDocument.Open(pdf.Finish()).SaveLinearized();

        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        Assert.Equal(50, again.Pages[0].MediaBox.Width);
    }

    [Fact]
    public void APageListedTwiceIsWrittenOnce()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 3 0 R 4 0 R] /Count 3 /MediaBox [0 0 50 50]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R>>");
        byte[] file = PdfDocument.Open(pdf.Finish()).SaveLinearized();

        var parameters = LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        Assert.Equal(2, parameters["N"]);
        Assert.Equal(2, again.Integer(again.Dict(again.Catalog, "Pages"), "Count"));
        Assert.Empty(again.Repairs);
    }

    [Fact]
    public void ACleanNestedTreeKeepsItsShape()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 3 /MediaBox [0 0 50 50]>>");
        pdf.Obj(3, "<</Type /Pages /Parent 2 0 R /Kids [5 0 R 6 0 R] /Count 2>>");
        pdf.Obj(4, "<</Type /Pages /Parent 2 0 R /Kids [7 0 R] /Count 1>>");
        for (int i = 0; i < 3; i++) pdf.Obj(5 + i, $"<</Type /Page /Parent {(i < 2 ? 3 : 4)} 0 R>>");
        byte[] file = PdfDocument.Open(pdf.Finish()).SaveLinearized();

        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        Assert.Equal(2, again.Array(again.Dict(again.Catalog, "Pages"), "Kids")!.Items.Count);
        Assert.Equal(3, again.Pages.Count);
    }

    [Fact]
    public void AWrongCountInTheTreeIsMadeRight()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 9 /MediaBox [0 0 50 50]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R>>");
        byte[] file = PdfDocument.Open(pdf.Finish()).SaveLinearized();

        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        Assert.Equal(2, again.Integer(again.Dict(again.Catalog, "Pages"), "Count"));
        Assert.Empty(again.Repairs);
    }

    [Fact]
    public void ContentStreamsThePagesShareAreLeftOutOfTheContentSpan()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 50 50]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents [6 0 R 7 0 R]>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents [7 0 R 8 0 R]>>");
        pdf.Obj(5, "<</Type /Page /Parent 2 0 R /Contents 7 0 R>>");
        pdf.Stream(6, "", "q Q");
        pdf.Stream(7, "", "0 0 m");
        pdf.Stream(8, "", "1 1 m");
        byte[] file = PdfDocument.Open(pdf.Finish()).SaveLinearized();

        LinearizerKit.Verify(file);
        using var again = PdfDocument.Open(file);
        Assert.Equal("0 0 m", Encoding.Latin1.GetString(again.Pages[2].Contents()));
    }

    [Fact]
    public void ManyPagesWithSharedResourcesAreDescribedExactly()
    {
        byte[] file = PdfDocument.Open(LinearizerKit.Make(300)).SaveLinearized();

        var parameters = LinearizerKit.Verify(file);
        Assert.Equal(300, parameters["N"]);
    }

    [Fact]
    public void ThumbnailsStayOutOfThePagesSections()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 50 50]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Thumb 6 0 R /Contents 5 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Thumb 7 0 R /Contents 5 0 R>>");
        pdf.Stream(5, "", "0 0 m");
        pdf.Stream(6, "/Width 1 /Height 1 /BitsPerComponent 8", "a");
        pdf.Stream(7, "/Width 1 /Height 1 /BitsPerComponent 8", "b");
        byte[] file = PdfDocument.Open(pdf.Finish()).SaveLinearized();

        var parameters = LinearizerKit.Verify(file);
        string text = Encoding.Latin1.GetString(file);
        Assert.True(text.IndexOf("/Width 1", StringComparison.Ordinal) > parameters["E"]);
    }

    [Fact]
    public void AFileSavedThroughTheSafeSaverStaysLinearized()
    {
        string path = Path.Combine(Path.GetTempPath(), $"lazypdf-lin-{Guid.NewGuid():N}.pdf");
        try
        {
            File.WriteAllBytes(path, LinearizerKit.Make(3));
            using var document = PdfDocument.Open(path);
            byte[] file = document.SaveLinearized();
            PdfFileSaver.Save(path, file);

            using var again = PdfDocument.Open(path);
            Assert.True(again.IsLinearized);
        }
        finally
        {
            File.Delete(path);
        }
    }
}
