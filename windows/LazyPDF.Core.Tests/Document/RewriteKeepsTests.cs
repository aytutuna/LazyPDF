using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RewriteKeepsTests
{
    [Fact]
    public void PagesFoundByScanningSurviveARewrite()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /MediaBox [0 0 100 100]>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /MediaBox [0 0 100 100]>>");
        pdf.Stream(5, "", "one");
        pdf.Stream(6, "", "two");
        var document = PdfDocument.Open(pdf.Finish());
        Assert.Equal(2, document.Pages.Count);

        var reopened = PdfDocument.Open(document.SaveRewrite());
        Assert.Equal(2, reopened.Pages.Count);
        Assert.Equal("two", TestPdf.Text(reopened.Pages[1].Contents()));
    }

    [Fact]
    public void ADamagedFlateStreamUnderATextFilterKeepsItsOriginalBytes()
    {
        byte[] plain = FilterFixtures.Text(400_000);
        byte[] flate = TestPdf.Deflate(plain);
        for (int i = 0; i < 40; i++) flate[flate.Length * 3 / 4 + i * 7] ^= 0x5A;
        string hex = Convert.ToHexString(flate) + ">";
        var pdf = TestPdf.WithPages(1);
        pdf.Stream(9, "/Filter [/ASCIIHexDecode /FlateDecode]", hex);
        pdf.Obj(10, "<</Type /Catalog /Pages 2 0 R /Extra 9 0 R>>");
        var document = PdfDocument.Open(pdf.Finish("/Root 10 0 R"));
        var stream = (PdfStream)document.Get(9)!;
        // The tolerant reader gets something out of it without complaint, which is how the damage hides.
        Assert.NotEqual(plain.Length, document.Data(stream).Length);

        var reopened = PdfDocument.Open(document.SaveRewrite());
        var kept = reopened.Resolve<PdfStream>(reopened.Catalog["Extra"])!;
        Assert.Equal(Encoding.ASCII.GetBytes(hex), reopened.RawData(kept));
    }
}
