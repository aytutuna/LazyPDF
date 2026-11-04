using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A glyph procedure paints where it pleases (ISO 32000-1 9.6.5): unless it is plain shapes near its box, the page becomes a picture.
public class RedactType3PaintTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";

    private static string Type3(string procedures, string names, string resources = "") =>
        $"<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <<{procedures}>> " +
        $"/Encoding <</Type /Encoding /Differences [97 {names}]>> /FirstChar 97 /LastChar {96 + names.Split(' ').Length} /Widths [{string.Join(' ', names.Split(' ').Select(_ => 1000))}] {resources}>>";

    private static PdfDocument Drawn() =>
        RedactionKit.Page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>> /XObject <</Im1 8 0 R>>", pdf =>
        {
            pdf.Obj(6, Type3("/a 7 0 R", "/a", "/Resources <</XObject <</Im1 8 0 R>>>>"));
            pdf.Stream(7, "", "1000 0 d0 q 10000 0 0 10000 20000 20000 cm /Im1 Do Q");
            pdf.Stream(8, ImageEntries, Pixels);
        });

    [Fact]
    public void PictureDrawnByAGlyphWhoseBoxIsClearOfTheMarkMakesThePagePicture()
    {
        using var document = Drawn();
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, new PdfRect(240, 240, 360, 360))], "ZQXPIXELSDATA");
    }

    [Fact]
    public void ShapesDrawnFarFromTheGlyphMakeThePagePictureWhenTheyMeetTheMark()
    {
        using var document = RedactionKit.Page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>>", pdf =>
        {
            pdf.Obj(6, Type3("/a 7 0 R", "/a"));
            pdf.Stream(7, "", "1000 0 d0 20000 20000 1000 1000 re f");
        });
        var elsewhere = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(400, 400, 500, 500))]);
        Assert.Equal(0, elsewhere.Report.Glyphs);
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, new PdfRect(240, 240, 360, 360))]);
    }

    [Fact]
    public void GlyphOfAType3FontUnderTheMarkMakesThePagePicture()
    {
        using var document = RedactionKit.Page("BT /T3 10 Tf 50 50 Td (ab) Tj ET", "/Font <</T3 6 0 R>>", pdf =>
        {
            pdf.Obj(6, Type3("/a 7 0 R /b 8 0 R", "/a /b"));
            pdf.Stream(7, "", "1000 0 d0 100 100 800 800 re f");
            pdf.Stream(8, "", "1000 0 0 0 1000 1000 d1 100 100 800 800 re f");
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, new PdfRect(40, 40, 58, 70))]);
    }

    [Fact]
    public void Type3GlyphOutsideTheMarksKeepsThePageAsText()
    {
        using var document = RedactionKit.Page("BT /T3 10 Tf 50 50 Td (a) Tj ET BT /F1 12 Tf 300 300 Td (ZQXWORD) Tj ET", "/Font <</T3 6 0 R>>", pdf =>
        {
            pdf.Obj(6, Type3("/a 7 0 R", "/a"));
            pdf.Stream(7, "", "1000 0 d0 100 100 800 800 re f");
        });
        var result = new PdfRedactor(document).Apply([RedactionKit.MarkOf(document, 0, "ZQXWORD")]);
        Assert.Empty(result.Report.Flattened);
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void ProcedureOutsideTheEncodingMakesThePagePicture()
    {
        using var document = RedactionKit.Page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>> /XObject <</Im1 9 0 R>>", pdf =>
        {
            pdf.Obj(6, Type3("/a 7 0 R /evil 8 0 R", "/a"));
            pdf.Stream(7, "", "1000 0 d0 100 100 800 800 re f");
            pdf.Stream(8, "", "1000 0 d0 q 1000 0 0 1000 0 0 cm /Im1 Do Q");
            pdf.Stream(9, ImageEntries, Pixels);
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, new PdfRect(40, 40, 58, 70))], "ZQXPIXELSDATA");
    }

    [Fact]
    public void FontMatrixThatTurnsTheGlyphMakesThePagePicture()
    {
        using var document = RedactionKit.Page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>>", pdf =>
        {
            pdf.Obj(6, Type3("/a 7 0 R", "/a").Replace("[0.001 0 0 0.001 0 0]", "[0 0.01 -0.01 0 0 0]"));
            pdf.Stream(7, "", "1000 0 d0 100 100 800 800 re f");
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, new PdfRect(40, 40, 58, 70))]);
    }

    [Fact]
    public void VerifyReportsAGlyphWhoseProcedurePaintsUnderAMark()
    {
        using var document = Drawn();
        var problems = PdfRedactor.Verify(document.SaveRewrite(), [RedactionMark.FromRect(0, new PdfRect(240, 240, 360, 360))], []).Problems;
        Assert.Contains(RedactionText.NotFollowed(0), problems);
    }

    [Fact]
    public void ProcedureThatPaintsAPictureInAFormMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R /Im1 9 0 R>> /Font <</T3 7 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800]", "BT /T3 10 Tf 50 50 Td (a) Tj ET BT /T3 10 Tf 200 200 Td (b) Tj ET");
            pdf.Obj(7, Type3("/a 8 0 R /b 10 0 R", "/a /b"));
            pdf.Stream(8, "", "1000 0 d0 q 1000 0 0 1000 0 0 cm /Im1 Do Q");
            pdf.Stream(9, ImageEntries, Pixels);
            pdf.Stream(10, "", "1000 0 d0 0 0 500 500 re f");
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, new PdfRect(40, 40, 80, 80))], "ZQXPIXELSDATA");
    }
}
