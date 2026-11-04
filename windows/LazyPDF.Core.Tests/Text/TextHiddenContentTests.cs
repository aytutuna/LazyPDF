using Xunit;

namespace LazyPDF.Core.Tests;

public class TextHiddenContentTests
{
    private static PdfDocument Layered(string off)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R /OCProperties <</OCGs [7 0 R 8 0 R] /D <</OFF [{off}]>>>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [10 0 R] /Count 1 /MediaBox [0 0 300 300]>>");
        pdf.Obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        pdf.Obj(7, "<</Type /OCG /Name (Notes)>>");
        pdf.Obj(8, "<</Type /OCG /Name (Extra)>>");
        pdf.Obj(9, "<</Type /OCMD /OCGs [7 0 R 8 0 R] /P /AllOn>>");
        pdf.Obj(10, "<</Type /Page /Parent 2 0 R /Contents 20 0 R /Resources <</Font <</F1 3 0 R>> /Properties <</L1 7 0 R /L2 8 0 R /M 9 0 R>> /XObject <</Fm 21 0 R>>>>>>");
        pdf.Stream(20, "", "BT /F1 12 Tf 20 250 Td (plain) Tj ET " +
            "/OC /L1 BDC BT /F1 12 Tf 20 200 Td (notes) Tj ET EMC " +
            "/OC /L2 BDC BT /F1 12 Tf 20 150 Td (extra) Tj ET EMC " +
            "/OC /M BDC BT /F1 12 Tf 20 100 Td (member) Tj ET EMC " +
            "/Fm Do");
        pdf.Stream(21, "/Type /XObject /Subtype /Form /BBox [0 0 300 300] /OC 7 0 R /Resources <</Font <</F1 3 0 R>>>>", "BT /F1 12 Tf 20 50 Td (inform) Tj ET");
        return PdfDocument.Open(pdf.Finish());
    }

    private static string Words(PdfDocument document) => string.Join(" ", TextPage.Create(document, document.Pages[0]).Words.Select(w => w.Text).Order());

    [Fact]
    public void TextInAGroupThatIsOffIsNotOnThePage()
    {
        Assert.Equal("extra plain", Words(Layered("7 0 R")));
    }

    [Fact]
    public void AMembershipDictionaryFollowsItsPolicy()
    {
        Assert.Equal("inform notes plain", Words(Layered("8 0 R")));
    }

    [Fact]
    public void WithEveryGroupOnAllTheTextCounts()
    {
        Assert.Equal("extra inform member notes plain", Words(Layered("")));
    }

    [Fact]
    public void AGroupTurnedBackOnReturnsItsText()
    {
        var document = Layered("7 0 R");
        PdfLayers.SetVisible(document, new PdfReference(7, 0), true);
        Assert.Equal("extra inform member notes plain", Words(document));
    }
}
