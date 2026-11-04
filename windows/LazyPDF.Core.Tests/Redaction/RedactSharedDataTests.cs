using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Cells, mask groups and shadings hold their data apart from the dictionaries that name them; painted under a mark they make the page a picture.
public class RedactSharedDataTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private const string GroupEntries = "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group <</S /Transparency /CS /DeviceGray>>";
    private const string Paints = "q 100 0 0 100 100 100 cm /Im1 Do Q";
    private const string Mask = "<</Type /Mask /S /Luminosity /G 7 0 R>>";
    private const string Axial = "<</ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 1 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1>>>>";
    private static readonly PdfRect Hole = new(200, 200, 300, 300);

    private static RedactionResult Redact(PdfDocument document) => RedactionKit.Apply(document, [RedactionMark.FromRect(0, Hole)]);

    private static string Cell(string resources) =>
        $"/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 600 800] /XStep 600 /YStep 800 /Resources <<{resources}>>";

    private static PdfDocument Tiled(string content) =>
        RedactionKit.Page(content, "/Pattern <</P1 6 0 R>> /XObject <</Im1 7 0 R>>", pdf =>
        {
            pdf.Stream(6, Cell("/XObject <</Im1 7 0 R>>"), Paints);
            pdf.Stream(7, ImageEntries, Pixels);
        });

    [Fact]
    public void PictureOnlyAPatternCellPaintedLeavesTheListWhenThePatternGoes()
    {
        using var document = Tiled("/Pattern cs /P1 scn 200 200 50 50 re f");
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void PictureOnlyAPatternCellPaintedLeavesTheListWhenTheCellIsEmptied()
    {
        using var document = Tiled("/Pattern cs /P1 scn 200 200 50 50 re f 10 10 5 5 re f");
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void GroupSharedByTwoMasksIsEmptiedWhenOneOfThemMeetsAMark()
    {
        using var document = RedactionKit.Page("/A gs 200 200 50 50 re f /B gs 10 10 5 5 re f", "/ExtGState <</A 6 0 R /B 8 0 R>>", pdf =>
        {
            pdf.Obj(6, $"<</Type /ExtGState /SMask {Mask}>>");
            pdf.Stream(7, GroupEntries + " /Resources <</XObject <</Im1 9 0 R>>>>", Paints);
            pdf.Obj(8, $"<</Type /ExtGState /SMask {Mask}>>");
            pdf.Stream(9, ImageEntries, Pixels);
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void ShadingSharedByTwoPatternsGoesWhenOneOfThemMeetsAMark()
    {
        using var document = RedactionKit.Page("/Pattern cs /SP1 scn 200 200 50 50 re f /SP2 scn 10 10 5 5 re f", "/Pattern <</SP1 6 0 R /SP2 7 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</PatternType 2 /Shading 8 0 R>>");
            pdf.Obj(7, "<</PatternType 2 /Shading 8 0 R>>");
            pdf.Stream(8, "/ShadingType 4 /ColorSpace /DeviceGray /BitsPerCoordinate 8 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 600 0 800 0 1]", "ZQXMESHSAMPLES");
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXMESHSAMPLES"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void CellThatPaintsAShadingPatternWithAMaskGroupIsEmptied()
    {
        using var document = RedactionKit.Page("/Pattern cs /P1 scn 200 200 50 50 re f 10 10 5 5 re f", "/Pattern <</P1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Cell("/Pattern <</SP 7 0 R>>"), "/Pattern cs /SP scn 0 0 600 800 re f");
            pdf.Obj(7, $"<</PatternType 2 /Shading {Axial} /ExtGState <</SMask <</Type /Mask /S /Luminosity /G 8 0 R>>>>>>");
            pdf.Stream(8, GroupEntries + " /Resources <</XObject <</Im1 9 0 R>>>>", Paints);
            pdf.Stream(9, ImageEntries, Pixels);
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void MaskGroupWithoutResourcesTakesThePagesAndIsEmptied()
    {
        using var document = RedactionKit.Page("/A gs 200 200 50 50 re f 10 10 5 5 re f", "/ExtGState <</A 7 0 R>> /XObject <</Im1 8 0 R>>", pdf =>
        {
            pdf.Stream(6, GroupEntries, Paints);
            pdf.Obj(7, "<</Type /ExtGState /SMask <</Type /Mask /S /Luminosity /G 6 0 R>>>>");
            pdf.Stream(8, ImageEntries, Pixels);
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }
}
