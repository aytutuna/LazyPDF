using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Soft masks, tiling cells and pictures that others name: under a mark a mask or a cell with more than shapes makes the page a picture, and what nothing paints is emptied whoever names it.
public class RedactMaskCellTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string MaskPixels = "ZQXMASKBYTESZQXMASKBYTESZQXMASKBYTESZQXMASKBYTESZQXMASKBYTESZQXM123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private const string Group = "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group <</S /Transparency /CS /DeviceGray>> /Resources <</XObject <</Im1 9 0 R>>>>";
    private const string TwoFills = "/Pattern cs /P1 scn 0 0 600 800 re f 10 10 5 5 re f";
    private static readonly PdfRect Hole = new(200, 200, 300, 300);

    private static RedactionResult Redact(PdfDocument document, PdfRect? area = null) =>
        RedactionKit.Apply(document, [RedactionMark.FromRect(0, area ?? Hole)]);

    private static string Cell(string resources) =>
        $"/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 600 800] /XStep 600 /YStep 800 /Resources <<{resources}>>";

    private const string Axial = "<</ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function <</FunctionType 2 /Domain [0 1] /N 1>>>>";

    [Fact]
    public void AxialShadingPaintedThroughASoftMaskTakesItsPictureWithIt()
    {
        using var document = RedactionKit.Page("/G gs /Sh0 sh", "/ExtGState <</G 6 0 R>> /Shading <</Sh0 7 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</Type /ExtGState /SMask <</Type /Mask /S /Alpha /G 8 0 R>>>>");
            pdf.Obj(7, Axial);
            pdf.Stream(8, Group, "q 300 0 0 300 50 50 cm /Im1 Do Q");
            pdf.Stream(9, ImageEntries, Pixels);
        });
        var result = Redact(document, new PdfRect(100, 100, 300, 300));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void EmptiedCellIsEmptyForEveryReferenceToIt()
    {
        using var document = RedactionKit.Page(TwoFills, "/Pattern <</P1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Cell("/XObject <</Im1 7 0 R>>"), "q 50 0 0 50 0 0 cm /Im1 Do Q");
            pdf.Stream(7, ImageEntries, Pixels);
        });
        document.Catalog["Keep"] = new PdfReference(6, 0);
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
        using var output = RedactionKit.Reopen(result.Bytes);
        Assert.Empty(output.Data((PdfStream)output.Resolve(output.Catalog["Keep"])!));
    }

    [Fact]
    public void EmptiedMaskIsEmptyForEveryReferenceToIt()
    {
        using var document = RedactionKit.Page("/GS1 gs 0 0 600 800 re f 10 10 5 5 re f", "/ExtGState <</GS1 6 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</Type /ExtGState /SMask 7 0 R>>");
            pdf.Obj(7, "<</Type /Mask /S /Alpha /G 8 0 R>>");
            pdf.Stream(8, Group, "q 100 0 0 100 100 100 cm /Im1 Do Q");
            pdf.Stream(9, ImageEntries, Pixels);
        });
        document.Catalog["Keep"] = new PdfReference(7, 0);
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void ShadingPatternWhoseOwnSoftMaskHoldsAPictureIsEmptied()
    {
        using var document = RedactionKit.Page(TwoFills, "/Pattern <</P1 6 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</PatternType 2 /Shading 7 0 R /ExtGState <</SMask <</Type /Mask /S /Alpha /G 8 0 R>>>>>>");
            pdf.Obj(7, Axial);
            pdf.Stream(8, Group, "q 100 0 0 100 100 100 cm /Im1 Do Q");
            pdf.Stream(9, ImageEntries, Pixels);
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void PictureBelowTheDepthTheInterpreterEntersStillMakesTheCellCarry()
    {
        using var document = RedactionKit.Page(TwoFills, "/Pattern <</P1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Cell("/XObject <</F0 7 0 R>>"), "/F0 Do");
            for (int i = 0; i < 24; i++)
            {
                string body = i < 23 ? $"/F{i + 1} Do" : "q 10 0 0 10 0 0 cm /Im1 Do Q";
                string resources = i < 23 ? $"/XObject <</F{i + 1} {8 + i} 0 R>>" : "/XObject <</Im1 31 0 R>>";
                pdf.Stream(7 + i, $"/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <<{resources}>>", body);
            }
            pdf.Stream(31, ImageEntries, Pixels);
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void MasksOfACutPictureLeaveTheResourceListsThatOnlyNamedThem()
    {
        using var document = RedactionKit.Page("q 100 0 0 100 100 100 cm /Im1 Do Q", "/XObject <</Im1 6 0 R /M1 7 0 R>>", pdf =>
        {
            pdf.Stream(6, ImageEntries + " /SMask 7 0 R", Pixels);
            pdf.Stream(7, ImageEntries, MaskPixels);
        });
        var result = Redact(document, new PdfRect(120, 120, 180, 180));
        Assert.Equal(1, result.Report.Images);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXMASKBYTES"));
    }

    [Fact]
    public void MaskThatAnotherPictureStillUsesMakesAPicture()
    {
        using var document = RedactionKit.Page("q 100 0 0 100 100 100 cm /Im1 Do Q q 50 0 0 50 400 400 cm /Im2 Do Q", "/XObject <</Im1 6 0 R /Im2 8 0 R>>", pdf =>
        {
            pdf.Stream(6, ImageEntries + " /SMask 7 0 R", Pixels);
            pdf.Stream(7, ImageEntries, MaskPixels);
            pdf.Stream(8, ImageEntries + " /SMask 7 0 R", Pixels);
        });
        RedactionKit.AssertFlattened(document, new PdfRect(120, 120, 180, 180));
    }

    [Fact]
    public void CutPictureKeepsTheMatteOfItsSoftMask()
    {
        using var document = RedactionKit.Page("q 100 0 0 100 100 100 cm /Im1 Do Q", "/XObject <</Im1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, ImageEntries + " /SMask 7 0 R", Pixels);
            pdf.Stream(7, ImageEntries + " /Matte [0]", MaskPixels);
        });
        var result = Redact(document, new PdfRect(120, 120, 180, 180));
        using var output = RedactionKit.Reopen(result.Bytes);
        var image = RedactionKit.Images(output).Single();
        Assert.NotNull(output.Stream(image.Stream!.Dictionary, "SMask")!.Dictionary["Matte"]);
    }

    [Fact]
    public void FormThatNothingPaintsAndShowsTheRemovedTextIsEmptied()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET", "/XObject <</Old 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET"));
        var result = Redact(document, new PdfRect(90, 90, 200, 120));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXCYCLE"));
    }

    [Fact]
    public void FormThatIsPaintedMayShowTheWordElsewhere()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET /Old Do", "/XObject <</Old 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 300 300 Td (ZQXCYCLE) Tj ET"));
        var result = Redact(document, new PdfRect(90, 90, 200, 120));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        Assert.Equal("ZQXCYCLE", RedactionKit.Text(RedactionKit.Reopen(result.Bytes)));
    }
}
