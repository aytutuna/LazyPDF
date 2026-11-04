using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Objects that a cut leaves behind: glyph procedures, resource lists inside fonts, references from other objects, keys copied along.
public class RedactSharedObjectTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string Other = "ZQXOTHERDATAZQXOTHERDATAZQXOTHERDATAZQXOTHERDATAZQXOTHERDATA1234";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private const string Type3 = "/Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.1 0 0 0.1 0 0] /Encoding <</Type /Encoding /Differences [97 /a /b]>> /FirstChar 97 /LastChar 98 /Widths [10 10]";
    private static readonly PdfRect Under = new(95, 95, 125, 125);

    private static RedactionResult Redact(PdfDocument document, PdfRect? mark = null) =>
        RedactionKit.Apply(document, [RedactionMark.FromRect(0, mark ?? Under)]);

    private static PdfDocument Glyphs(string text) =>
        RedactionKit.Page($"BT /F3 12 Tf 100 100 Td {text} ET", "/Font <</F3 6 0 R>>", pdf =>
        {
            pdf.Obj(6, $"<<{Type3} /CharProcs <</a 7 0 R /b 8 0 R>> /Resources <</XObject <</Im1 9 0 R>>>>>>");
            pdf.Stream(7, "", "10 0 d0 q 8 0 0 8 0 0 cm /Im1 Do Q");
            pdf.Stream(8, "", "10 0 d0 0 0 5 5 re f");
            pdf.Stream(9, ImageEntries, Pixels);
        });

    [Fact]
    public void FontWhoseGlyphPaintsAPictureMakesThePagePicture()
    {
        using var document = Glyphs("(a) Tj 200 0 Td (b) Tj");
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Under)], "ZQXPIXELSDATA");
    }

    [Fact]
    public void PictureListedInAType3FontHeldDirectlyIsNotLeftBehind()
    {
        using var document = ContentTestPdf.Page("q 30 0 0 30 100 100 cm /Im1 Do Q",
            $"/Font <</F1 5 0 R /F3 <<{Type3} /CharProcs <</a 7 0 R>> /Resources <</XObject <</Im1 6 0 R>>>>>>>> /XObject <</Im1 6 0 R>>", pdf =>
            {
                pdf.Obj(5, RedactionKit.Helvetica);
                pdf.Stream(6, ImageEntries, Pixels);
                pdf.Stream(7, "", "10 0 d0 0 0 5 5 re f");
            });
        var result = Redact(document, new PdfRect(95, 95, 135, 135));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void AlternateImageNamingACutOriginalDoesNotKeepIt()
    {
        using var document = RedactionKit.Page("q 30 0 0 30 100 100 cm /Im1 Do Q q 20 0 0 20 400 400 cm /Im2 Do Q", "/XObject <</Im1 6 0 R /Im2 7 0 R>>", pdf =>
        {
            pdf.Stream(6, ImageEntries, Pixels);
            pdf.Stream(7, $"{ImageEntries} /Alternates [<</Image 6 0 R /DefaultForPrinting true>>]", Other);
        });
        var result = Redact(document, new PdfRect(95, 95, 135, 135));
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
        Assert.True(RedactionKit.Holds(result.Bytes, "ZQXOTHERDATA"));
    }

    [Fact]
    public void CutImageDoesNotKeepAnAttachedFileOrAnyOtherReference()
    {
        using var document = RedactionKit.Page("q 30 0 0 30 100 100 cm /Im1 Do Q", "/XObject <</Im1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, $"{ImageEntries} /AF [<</Type /Filespec /F (source.png) /EF <</F 7 0 R>>>>] /Measure <</Subtype /RL /R (ZQXMEASURE)>>", Pixels);
            pdf.Stream(7, "/Type /EmbeddedFile", "ZQXSOURCEFILE");
        });
        var result = Redact(document, new PdfRect(95, 95, 135, 135));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSOURCEFILE"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXMEASURE"));
    }

    [Fact]
    public void CopiedFormDoesNotKeepAnAttachedFile()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>> /AF [<</Type /Filespec /F (source.txt) /EF <</F 7 0 R>>>>]", "BT /F1 12 Tf 100 100 Td (ZQXFORMTEXT) Tj ET");
            pdf.Stream(7, "/Type /EmbeddedFile", "ZQXSOURCEFILE");
        });
        var result = Redact(document, new PdfRect(90, 90, 200, 120));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXFORMTEXT"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSOURCEFILE"));
    }
}
