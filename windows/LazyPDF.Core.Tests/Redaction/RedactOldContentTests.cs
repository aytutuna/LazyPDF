using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// The page content that was replaced must not stay reachable under another key.
public class RedactOldContentTests
{
    private static readonly PdfRect Near = new(90, 90, 200, 120);

    [Fact]
    public void OtherKeyNamingTheReplacedContentDoesNotKeepIt()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 100 Td [(ZQX) -1 (CYCLE)] TJ ET");
        document.Pages[0].Dictionary["Keep"] = new PdfReference(4, 0);
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)]);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQX"));
        Assert.False(RedactionKit.Holds(result.Bytes, "CYCLE"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void ContentOfAnotherPageThatStillUsesItStays()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 6 0 R>>>>>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 6 0 R>>>>>>");
        pdf.Stream(5, "", "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET");
        pdf.Obj(6, RedactionKit.Helvetica);
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)]);
        using var output = RedactionKit.Open(result);
        Assert.Equal("", RedactionKit.Text(output, 0));
        Assert.Equal("ZQXCYCLE", RedactionKit.Text(output, 1));
    }

    [Fact]
    public void ReferenceNestedDeeperThanThirtyLevelsIsTakenOutToo()
    {
        const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
        using var document = RedactionKit.Page("q 100 0 0 100 100 100 cm /Im1 Do Q", "/XObject <</Im1 6 0 R>>",
            pdf => pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8", Pixels));
        PdfObject deep = new PdfReference(6, 0);
        for (int i = 0; i < 40; i++) deep = new PdfArray([deep]);
        document.Pages[0].Dictionary["Keep"] = deep;
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(90, 90, 210, 210))]);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }
}
