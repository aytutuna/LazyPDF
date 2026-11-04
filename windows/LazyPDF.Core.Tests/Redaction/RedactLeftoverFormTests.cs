using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// What a form that was cut or copied leaves behind: the pictures it painted, and an original that is still painted out of sight.
public class RedactLeftoverFormTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private const string Shows = "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET";
    private static readonly PdfRect Near = new(90, 90, 200, 120);

    private static string Form(string resources) =>
        $"/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> {resources}>>";

    private static RedactionResult Redact(PdfDocument document) => RedactionKit.Apply(document, [RedactionMark.FromRect(0, Near)]);

    [Fact]
    public void PictureOfAFormThatGoesWholeIsTakenOutOfTheListThatNamesIt()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R /Im1 7 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800]", "q 100 0 0 100 100 100 cm /Im1 Do Q /Fm Do");
            pdf.Stream(7, ImageEntries, Pixels);
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void FormPaintedAgainOffThePageMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/Fm Do q 1 0 0 1 5000 0 cm /Fm Do Q", "/XObject <</Fm 6 0 R>>", pdf =>
            pdf.Stream(6, Form(""), Shows));
        RedactionKit.AssertFlattened(document, Near, "ZQXCYCLE");
    }

    [Fact]
    public void FormPaintedAgainByATilingCellMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/Fm Do /Pattern cs /P1 scn 300 300 5 5 re f", "/XObject <</Fm 6 0 R>> /Pattern <</P1 7 0 R>>", pdf =>
        {
            pdf.Stream(6, Form(""), Shows);
            pdf.Stream(7, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <</XObject <</Fm 6 0 R>>>>", "/Fm Do");
        });
        RedactionKit.AssertFlattened(document, Near, "ZQXCYCLE");
    }

    [Fact]
    public void FormPaintedAgainInPlainViewMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/Fm Do q 1 0 0 1 300 300 cm /Fm Do Q", "/XObject <</Fm 6 0 R>>", pdf =>
            pdf.Stream(6, Form(""), Shows));
        RedactionKit.AssertFlattened(document, Near, "ZQXCYCLE");
    }

    [Fact]
    public void FormNothingPaintsIsEmptiedWithTheText()
    {
        using var document = RedactionKit.Page(Shows, "/XObject <</Fm 6 0 R>>", pdf =>
            pdf.Stream(6, Form(""), "BT /F1 12 Tf 10 10 Td [(ZQX) -1 (CYCLE)] TJ ET"));
        var result = Redact(document);
        Assert.Empty(result.Report.Flattened);
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        Assert.False(RedactionKit.Holds(result.Bytes, "CYCLE"));
    }

    [Fact]
    public void VerifyReadsTheTextAFormNothingPaintsWouldShow()
    {
        using var document = RedactionKit.Page(Shows, "/XObject <</Fm 6 0 R>>", pdf =>
            pdf.Stream(6, Form(""), "BT /F1 12 Tf 10 10 Td [(ZQX) -1 (CYCLE)] TJ ET"));
        Assert.False(PdfRedactor.Verify(document.SaveRewrite(), [], ["ZQXCYCLE"]).IsClean);
    }
}
