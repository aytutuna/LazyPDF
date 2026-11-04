using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// What is left in the lists of a page after a removal: only what the new content names.
public class RedactPruneTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private static readonly PdfRect Hole = new(200, 200, 300, 300);

    private static RedactionResult Redact(PdfDocument document, PdfRect? mark = null) =>
        RedactionKit.Apply(document, [RedactionMark.FromRect(0, mark ?? Hole)]);

    private static PdfDocument TwoPages(string first, string second, string shared, Action<TestPdf> more)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources 9 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources 9 0 R>>");
        pdf.Stream(5, "", first);
        pdf.Stream(6, "", second);
        pdf.Obj(7, RedactionKit.Helvetica);
        pdf.Obj(9, shared);
        more(pdf);
        return PdfDocument.Open(pdf.Finish());
    }

    [Fact]
    public void PatternFillWithAPictureInItsCellMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/Pattern cs /P1 scn 150 150 200 200 re f", "/Pattern <</P1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 50 50] /XStep 50 /YStep 50 /Resources <</XObject <</Im1 7 0 R>>>>", "q 50 0 0 50 0 0 cm /Im1 Do Q");
            pdf.Stream(7, ImageEntries, Pixels);
        });
        RedactionKit.AssertFlattened(document, Hole, "ZQXPIXELSDATA");
    }

    [Fact]
    public void PatternWithAPictureIsEmptiedForTheOtherPaintsToo()
    {
        using var document = RedactionKit.Page("/Pattern cs /P1 scn 150 150 200 200 re f 400 400 50 50 re f", "/Pattern <</P1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 50 50] /XStep 50 /YStep 50 /Resources <</XObject <</Im1 7 0 R>>>>", "q 50 0 0 50 0 0 cm /Im1 Do Q");
            pdf.Stream(7, ImageEntries, Pixels);
        });
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void SoftMaskOfARemovedShapeIsDropped()
    {
        using var document = RedactionKit.Page("/GS1 gs 210 210 m 280 210 l 250 280 l f", "/ExtGState <</GS1 6 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 7 0 R >> >>");
            pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group << /S /Transparency /CS /DeviceGray >> /Resources <</XObject <</Im1 8 0 R>>>>", "q 100 0 0 100 100 100 cm /Im1 Do Q");
            pdf.Stream(8, ImageEntries, Pixels);
        });
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void MeshShadingUnderTheMarkIsRemovedWithItsData()
    {
        using var document = RedactionKit.Page("/Sh1 sh", "/Shading <</Sh1 6 0 R>>", pdf =>
            pdf.Stream(6, "/ShadingType 4 /ColorSpace /DeviceGray /BitsPerCoordinate 8 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 600 0 800 0 1]", "ZQXMESHDATAZQXMESHDATA"));
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXMESHDATA"));
        Assert.DoesNotContain("Sh1 sh", RedactionKit.Latin(output));
        Assert.Equal(1, result.Report.Paths);
    }

    private static PdfDocument TwoFonts(string content, Action<TestPdf>? more = null) =>
        ContentTestPdf.Page(content, "/Font <</F1 5 0 R /F2 6 0 R>>", pdf =>
        {
            pdf.Obj(5, RedactionKit.Helvetica);
            pdf.Obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /ZQXSubset /FirstChar 65 /LastChar 66 /Widths [500 500] /ToUnicode 7 0 R>>");
            pdf.Stream(7, "", "ZQXTOUNICODE");
            more?.Invoke(pdf);
        });

    [Fact]
    public void FontOnlyTheRemovedTextUsedIsDropped()
    {
        using var document = TwoFonts("BT /F1 12 Tf 50 100 Td (visible) Tj /F2 12 Tf 0 400 Td (AB) Tj ET");
        var result = Redact(document, new PdfRect(40, 490, 100, 520));
        using var output = RedactionKit.Open(result);
        Assert.Equal("visible", RedactionKit.Text(output));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXTOUNICODE"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSubset"));
    }

    [Fact]
    public void FontStillShowingTextElsewhereStays()
    {
        using var document = TwoFonts("BT /F2 12 Tf 50 100 Td (AB) Tj 0 400 Td (AB) Tj ET");
        var result = Redact(document, new PdfRect(40, 490, 100, 520));
        using var output = RedactionKit.Open(result);
        Assert.Equal("AB", RedactionKit.Text(output));
        Assert.True(RedactionKit.Holds(result.Bytes, "ZQXTOUNICODE"));
    }

    [Fact]
    public void PictureListedByAnotherFormIsNotLeftBehind()
    {
        using var document = RedactionKit.Page("/Fm1 Do /Fm2 Do", "/XObject <</Fm1 6 0 R /Fm2 7 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources 9 0 R", "q 160 0 0 160 100 100 cm /Im0 Do Q");
            pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources 9 0 R", "0 g 0 0 1 1 re f");
            pdf.Stream(8, ImageEntries, Pixels);
            pdf.Obj(9, "<</XObject <</Im0 8 0 R>>>>");
        });
        var result = Redact(document, new PdfRect(100, 220, 140, 260));
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, Pixels));
        Assert.Equal(1, result.Report.Images);
    }

    [Fact]
    public void PropertyListOfARewrittenSequenceDoesNotStayInASharedResourceList()
    {
        const string Shared = "<</Font <</F1 7 0 R>> /Properties <</P1 << /MCID 0 /ActualText (ZQXACTUALTEXT) >> >> >>";
        using var document = TwoPages("/Span /P1 BDC BT /F1 12 Tf 50 700 Td (secretword) Tj ET EMC", "BT /F1 12 Tf 50 700 Td (other) Tj ET", Shared, _ => { });
        var result = Redact(document, new PdfRect(40, 690, 200, 720));
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXACTUALTEXT"));
        Assert.Equal("other", RedactionKit.Text(output, 1));
    }
}
