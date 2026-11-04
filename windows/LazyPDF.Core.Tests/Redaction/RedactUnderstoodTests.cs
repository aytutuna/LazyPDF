using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A page is redacted as text only when it is understood in full; every construct outside the list makes it a picture.
public class RedactUnderstoodTests
{
    private const string Word = "BT /F1 12 Tf 100 100 Td (ZQXWORD) Tj ET";
    private static readonly PdfRect Near = new(90, 90, 200, 120);

    [Theory]
    [InlineData("foo " + Word)]
    [InlineData("BX " + Word + " EX")]
    [InlineData("BT /F1 12 Tf (x) 100 Td (ZQXWORD) Tj ET")]
    [InlineData("BT /F1 12 Tf 1 100 100 Td (ZQXWORD) Tj ET")]
    [InlineData("BT 12 /F1 Tf 100 100 Td (ZQXWORD) Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td (ZQXWORD) 5 Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td [(ZQXWORD) /x] TJ ET")]
    [InlineData("1 2 " + Word)]
    [InlineData("Q " + Word)]
    [InlineData("q q Q Q Q " + Word)]
    public void StrayOperatorsOperandsOfTheWrongKindAndUnbalancedRestoresMakeThePagePicture(string content)
    {
        using var document = RedactionKit.Page(content);
        RedactionKit.AssertFlattened(document, Near, "ZQXWORD");
    }

    [Fact]
    public void XObjectOfAnyKindButImageAndFormMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/X1 Do " + Word, "/XObject <</X1 6 0 R>>", pdf => pdf.Stream(6, "/Type /XObject /Subtype /PS", "ZQXPOSTSCRIPT"));
        RedactionKit.AssertFlattened(document, Near, "ZQXWORD", "ZQXPOSTSCRIPT");
    }

    [Theory]
    [InlineData("q BI /W 2 /H 2 /BPC 8 /CS /G ID abcdefghij EI Q ")]
    [InlineData("q BI /W 2 /H 2 /BPC 8 /CS /Cs9 ID abcd EI Q ")]
    [InlineData("q BI /W 2 /H 2 /CS /G ID abcd EI Q ")]
    [InlineData("q BI /W 2 /H 1 /BPC 8 /CS /RGB /F /AHx ID 000000000000> EI Q ")]
    [InlineData("q BI /W 1 /H 4 /BPC 8 /CS /G /F [] ID abcd EI Q ")]
    [InlineData("q BI /W 1 /H 4 /Width 40 /BPC 8 /CS /G ID abcd EI Q ")]
    [InlineData("q BI /W 1 /H 4 /BPC 8 /CS /G /Note (ZQXWORD) ID abcd EI Q ")]
    [InlineData("q BI /W 1 /H 4 /BPC 8 /CS /G BT /F1 12 Tf 100 100 Td (ZQXWORD) Tj ET ID abcd EI Q ")]
    public void InlineImageWhoseLengthDoesNotMatchItsDimensionsMakesThePagePicture(string image)
    {
        using var document = RedactionKit.Page(image + Word);
        RedactionKit.AssertFlattened(document, Near, "ZQXWORD");
    }

    [Theory]
    [InlineData("q BI /W 2 /H 2 /BPC 8 /CS /G ID abcd EI Q ")]
    [InlineData("q BI /W 8 /H 2 /IM true ID ab EI Q ")]
    [InlineData("q BI /W 2 /H 1 /BPC 8 /CS [/I /RGB 1 <000000ffffff>] ID ab EI Q ")]
    public void InlineImageWithItsEndInPlaceKeepsThePageAsText(string image)
    {
        using var document = RedactionKit.Page(image + Word);
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)]);
        Assert.Empty(result.Report.Flattened);
        Assert.Equal(7, result.Report.Glyphs);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXWORD"));
    }

    [Fact]
    public void NameFoundOnlyInAnEnclosingListMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</ProcSet [/PDF]>>", Word));
        RedactionKit.AssertFlattened(document, Near, "ZQXWORD");
    }

    [Fact]
    public void FormWithNoResourcesOfItsOwnTakesTheOnesItIsPaintedFrom()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800]", Word));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)]);
        Assert.Empty(result.Report.Flattened);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXWORD"));
    }

    [Fact]
    public void SoftMaskThatMeetsAMarkMakesThePagePictureAndOneThatDoesNotDoesNot()
    {
        const string State = "/ExtGState <</G 6 0 R>>";
        void Objects(TestPdf pdf)
        {
            pdf.Obj(6, "<</Type /ExtGState /SMask <</Type /Mask /S /Alpha /G 7 0 R>>>>");
            pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group <</S /Transparency>>", "0 0 600 800 re f");
        }
        using var meets = RedactionKit.Page("/G gs 80 80 200 80 re f " + Word, State, Objects);
        RedactionKit.AssertFlattened(meets, Near, "ZQXWORD");

        using var clear = RedactionKit.Page("q /G gs 300 300 100 100 re f Q " + Word, State, Objects);
        var result = new PdfRedactor(clear).Apply([RedactionMark.FromRect(0, Near)]);
        Assert.Empty(result.Report.Flattened);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXWORD"));
    }

    [Fact]
    public void OptionalContentUnderAMarkMakesThePagePictureAndOneElsewhereDoesNot()
    {
        const string Layer = "/Properties <</MC0 <</Type /OCG /Name (Layer)>>>>";
        using var under = RedactionKit.Page("/OC /MC0 BDC " + Word + " EMC", Layer);
        RedactionKit.AssertFlattened(under, Near, "ZQXWORD");

        using var elsewhere = RedactionKit.Page("/OC /MC0 BDC BT /F1 12 Tf 300 300 Td (other) Tj ET EMC " + Word, Layer);
        var result = new PdfRedactor(elsewhere).Apply([RedactionMark.FromRect(0, Near)]);
        Assert.Empty(result.Report.Flattened);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXWORD"));
    }

    [Fact]
    public void OrdinaryPageWithShapesImagesFormsAndMarkedContentStaysText()
    {
        using var document = RedactionKit.Page("q 0.5 g 300 300 100 100 re f Q /Fm Do /Span <</MCID 0>> BDC " + Word + " EMC q 50 0 0 50 400 400 cm /Im1 Do Q BT /F1 12 Tf 100 500 Td [(kept) -20 (text)] TJ ET",
            "/XObject <</Fm 6 0 R /Im1 7 0 R>>", pdf =>
            {
                pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 300 600 Td (inside) Tj ET");
                pdf.Stream(7, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", "a");
            });
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)]);
        Assert.Empty(result.Report.Flattened);
        Assert.Equal(7, result.Report.Glyphs);
        using var output = RedactionKit.Open(result);
        Assert.Contains("inside", RedactionKit.Text(output));
    }

    [Fact]
    public void VerifyReportsAPageThatIsNotUnderstood()
    {
        using var document = RedactionKit.Page("foo " + Word);
        var problems = PdfRedactor.Verify(document.SaveRewrite(), [RedactionMark.FromRect(0, new PdfRect(300, 300, 400, 400))], []).Problems;
        Assert.Equal(RedactionText.NotFollowed(0), Assert.Single(problems));
    }

    [Fact]
    public void ContentOfAPageWithoutMarksIsNotJudged()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>>>>>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>>>>>>");
        pdf.Stream(5, "", Word);
        pdf.Stream(6, "", "foo BT /F1 12 Tf 100 100 Td (ZQXOTHER) Tj ET");
        pdf.Obj(7, RedactionKit.Helvetica);
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXWORD"));
        Assert.Empty(result.Report.Flattened);
        Assert.True(RedactionKit.Holds(result.Bytes, "ZQXOTHER"));
    }
}
