using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// The interpreter skips a form that is already being run, so what a form that reaches itself shows is never looked at: the page becomes a picture.
public class RedactCycleTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private static readonly PdfRect Near = new(90, 90, 200, 120);

    private static string Form(string resources) => $"/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> {resources}>>";

    [Fact]
    public void FormThatPaintsItselfGoesWholeWhereItMeetsAMark()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
            pdf.Stream(6, Form("/XObject <</Fm 6 0 R>>"), "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET q 1 0 0 1 5000 0 cm /Fm Do Q"));
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXCYCLE");
    }

    [Fact]
    public void FormsThatPaintEachOtherGoWholeWhereTheyMeetAMark()
    {
        using var document = RedactionKit.Page("/A Do", "/XObject <</A 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Form("/XObject <</B 7 0 R>>"), "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET q 1 0 0 1 5000 0 cm /B Do Q");
            pdf.Stream(7, Form("/XObject <</A 6 0 R>>"), "q 1 0 0 1 0 5000 cm /A Do Q");
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXCYCLE");
    }

    [Fact]
    public void ImageInAFormThatPaintsItselfIsNotLeftUncut()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Form("/XObject <</Fm 6 0 R /Im1 7 0 R>>"), "q 30 0 0 30 100 100 cm /Im1 Do Q q 1 0 0 1 5000 0 cm /Fm Do Q");
            pdf.Stream(7, ImageEntries, Pixels);
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXPIXELSDATA");
    }

    [Fact]
    public void FormThatPaintsItselfAwayFromTheMarksMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/Fm Do BT /F1 12 Tf 100 100 Td (ZQXGONE) Tj ET", "/XObject <</Fm 6 0 R>>", pdf =>
            pdf.Stream(6, Form("/XObject <</Fm 6 0 R>>").Replace("[0 0 600 800]", "[250 250 400 400]"), "BT /F1 12 Tf 300 300 Td (ZQXKEPT) Tj ET q 1 0 0 1 5000 0 cm /Fm Do Q"));
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXGONE", "ZQXKEPT");
    }
}
