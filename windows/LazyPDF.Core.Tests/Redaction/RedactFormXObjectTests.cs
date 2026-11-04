using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactFormXObjectTests
{
    private const string Form = "/Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources <</Font <</F1 5 0 R>>>>";

    private static string TextOf(PdfDocument document, int page = 0) => RedactionKit.Text(document, page);

    // A form drawing the marker once, painted twice: at y 100 and y 500.
    private static PdfDocument TwoPlacements() =>
        RedactionKit.Page("q 1 0 0 1 50 100 cm /Fm1 Do Q q 1 0 0 1 50 500 cm /Fm1 Do Q", "/XObject <</Fm1 6 0 R>>",
            pdf => pdf.Stream(6, Form, "BT /F1 12 Tf 10 50 Td (ZQXMARKER) Tj ET"));

    [Fact]
    public void FormUsedTwiceIsCutOnlyWhereTheMarkIs()
    {
        using var document = TwoPlacements();
        var glyphs = RedactionKit.Glyphs(document);
        Assert.Equal(18, glyphs.Count);
        var mark = RedactionMark.FromRect(0, new PdfRect(40, 140, 200, 170));
        var result = new PdfRedactor(document).Apply([mark]);
        using var output = RedactionKit.Open(result);
        var after = RedactionKit.Glyphs(output);
        Assert.Equal(9, after.Count);
        Assert.All(after, g => Assert.Equal(550, g.Y, 0.01));
        Assert.Equal(9, result.Report.Glyphs);
        Assert.Equal("ZQXMARKER", RedactionKit.Text(after));
    }

    [Fact]
    public void FormUsedOnTwoPagesKeepsItsTextOnTheOther()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</XObject <</Fm1 7 0 R>>>>>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</XObject <</Fm1 7 0 R>>>>>>");
        pdf.Stream(5, "", "q 1 0 0 1 50 100 cm /Fm1 Do Q");
        pdf.Obj(6, ContentTestPdf.Helvetica);
        pdf.Stream(7, Form.Replace("5 0 R", "6 0 R"), "BT /F1 12 Tf 10 50 Td (ZQXMARKER) Tj ET");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(40, 140, 200, 170))]);
        using var output = RedactionKit.Open(result);
        Assert.Equal("", TextOf(output, 0));
        Assert.Equal("ZQXMARKER", TextOf(output, 1));
    }

    [Fact]
    public void NestedFormsAreCopiedAlongTheChain()
    {
        using var document = RedactionKit.Page("q 1 0 0 1 50 100 cm /Outer Do Q q 1 0 0 1 50 500 cm /Outer Do Q", "/XObject <</Outer 6 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources <</Font <</F1 5 0 R>> /XObject <</Inner 7 0 R>>>>", "q 1 0 0 1 0 20 cm /Inner Do Q BT /F1 12 Tf 10 5 Td (outer) Tj ET");
            pdf.Stream(7, Form, "BT /F1 12 Tf 10 30 Td (ZQXMARKER) Tj ET");
        });
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(40, 150, 300, 185))]);
        using var output = RedactionKit.Open(result);
        var after = RedactionKit.Glyphs(output);
        Assert.Equal("outer" + "ZQXMARKER" + "outer", RedactionKit.Text(after));
        Assert.DoesNotContain(after, g => g.Text == "Z" && g.Y < 300);
    }

    [Fact]
    public void ImageInsideAFormIsCutOnACopyOfTheForm()
    {
        var data = Enumerable.Repeat((byte)7, 16).ToArray();
        using var document = RedactionKit.Page("q 1 0 0 1 50 100 cm /Fm1 Do Q q 1 0 0 1 50 500 cm /Fm1 Do Q", "/XObject <</Fm1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources <</XObject <</Im 7 0 R>>>>", "q 100 0 0 100 0 0 cm /Im Do Q");
            pdf.Stream(7, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8", data);
        });
        // The image is 100 points square at 50..150 over 100..200: its top left pixel.
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(50, 175, 70, 200))]);
        using var output = RedactionKit.Open(result);
        var images = RedactionKit.Images(output);
        Assert.Equal(2, images.Count);
        Assert.Equal(0, output.Data(images[0].Stream!)[0]);
        Assert.Equal(7, output.Data(images[1].Stream!)[0]);
    }

    [Fact]
    public void FormWithoutResourcesOfItsOwnStillWorks()
    {
        using var document = RedactionKit.Page("q 1 0 0 1 50 100 cm /Fm1 Do Q", "/XObject <</Fm1 6 0 R>>",
            pdf => pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 300 100]", "BT /F1 12 Tf 10 50 Td (ZQXMARKER) Tj ET"));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(40, 140, 200, 170))]);
        using var output = RedactionKit.Open(result);
        Assert.Equal("", TextOf(output));
    }

    [Fact]
    public void FormThatMissesTheMarkIsNotCopied()
    {
        using var document = TwoPlacements();
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(400, 400, 450, 450))]);
        using var output = RedactionKit.Open(result);
        Assert.Equal(18, RedactionKit.Glyphs(output).Count);
        Assert.Single(output.ObjectNumbers.Select(output.Get).OfType<PdfStream>(), s => output.Name(s.Dictionary, "Subtype") == "Form");
    }

    [Fact]
    public void ActualTextAndAltOfTheMarkedContentGoWithTheText()
    {
        string content = "/Span <</ActualText (ZQXMARKER secret) /MCID 0>> BDC BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET EMC " +
                         "/Figure /P1 BDC BT /F1 12 Tf 50 600 Td (ZQXMARKER) Tj ET EMC " +
                         "/Span <</ActualText (kept text)>> BDC BT /F1 12 Tf 50 500 Td (kept) Tj ET EMC";
        using var document = RedactionKit.Page(content, "/Properties <</P1 <</Alt (ZQXMARKER figure) /MCID 1>>>>");
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXMARKER"));
        using var output = RedactionKit.Open(result);
        string after = RedactionKit.Latin(output);
        Assert.DoesNotContain("ZQXMARKER", after);
        Assert.Contains("kept text", after);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXMARKER"));
        Assert.Contains("/MCID 0", after);
        Assert.Equal("kept", RedactionKit.Text(output));
    }
}
