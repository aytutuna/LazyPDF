using Xunit;

namespace LazyPDF.Core.Tests;

// Streams whose /JBIG2Globals point at themselves or at each other must not be followed round.
public class Jbig2GlobalsTests
{
    private static PdfDocument Open(TestPdf pdf) => PdfDocument.Open(pdf.Finish());

    [Fact]
    public void AStreamThatNamesItselfAsItsGlobalsIsReadAsItIs()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Stream(7, "/DecodeParms <</JBIG2Globals 7 0 R>>", "x");
        var document = Open(pdf);
        Assert.Equal("x", TestPdf.Text(document.Data((PdfStream)document.Get(7)!)));
    }

    [Fact]
    public void FlateStreamWithGlobalsInItsParametersIgnoresThem()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Stream(7, "/Filter /FlateDecode /DecodeParms <</JBIG2Globals 8 0 R>>", TestPdf.Deflate(TestPdf.Latin("abc")));
        pdf.Stream(8, "/Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 7 0 R>>", "junk");
        var document = Open(pdf);
        Assert.Equal("abc", TestPdf.Text(document.Data((PdfStream)document.Get(7)!)));
    }

    [Fact]
    public void TwoJbig2StreamsThatNameEachOtherAreDamage()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Stream(7, "/Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 8 0 R>>", "a");
        pdf.Stream(8, "/Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 7 0 R>>", "b");
        var document = Open(pdf);
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => document.Data((PdfStream)document.Get(7)!)).Problem);
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => document.Data((PdfStream)document.Get(8)!)).Problem);
    }

    [Fact]
    public void ALongChainOfGlobalsIsNotFollowed()
    {
        var pdf = TestPdf.WithPages(1);
        for (int n = 7; n < 3007; n++) pdf.Stream(n, $"/DecodeParms <</JBIG2Globals {n + 1} 0 R>>", "x");
        pdf.Stream(3007, "", "end");
        var document = Open(pdf);
        Assert.Equal("x", TestPdf.Text(document.Data((PdfStream)document.Get(7)!)));
    }

    [Fact]
    public void GlobalsAreDecodedOnceForAllTheImagesThatUseThem()
    {
        var sample = Jbig2Samples.WithGlobals();
        var pdf = TestPdf.WithPages(1);
        pdf.Stream(7, "", Jbig2Samples.Globals());
        const string Entries = "/Type /XObject /Subtype /Image /Width 64 /Height 40 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 7 0 R>>";
        pdf.Stream(8, Entries, sample.Data);
        pdf.Stream(9, Entries, sample.Data);
        var document = Open(pdf);
        Assert.Equal(document.Data((PdfStream)document.Get(8)!), document.Data((PdfStream)document.Get(9)!));
    }

    [Fact]
    public void BrokenGlobalsAreAFailureNotEmptyGlobals()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Stream(7, "/Filter /FlateDecode", "not flate data at all");
        pdf.Stream(8, "/Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 7 0 R>>", Jbig2Samples.WithGlobals().Data);
        var document = Open(pdf);
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => document.Data((PdfStream)document.Get(8)!)).Problem);
    }
}
