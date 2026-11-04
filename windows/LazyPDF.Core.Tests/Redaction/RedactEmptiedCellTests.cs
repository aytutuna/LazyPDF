using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A cell or mask group with other uses is emptied when it holds a picture or text; what counts as holding one.
public class RedactEmptiedCellTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private const string Group = "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group << /S /Transparency /CS /DeviceGray >> /Resources <</XObject <</Im1 9 0 R>>>>";
    private const string TwoFills = "/Pattern cs /P1 scn 0 0 600 800 re f 10 10 5 5 re f";
    private static readonly PdfRect Hole = new(200, 200, 300, 300);

    private static RedactionResult Redact(PdfDocument document) => new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Hole)]);

    private static string Cell(string resources) =>
        $"/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 600 800] /XStep 600 /YStep 800 /Resources <<{resources}>>";

    [Fact]
    public void PatternCellWhosePictureIsInASoftMaskGroupIsEmptied()
    {
        using var document = RedactionKit.Page(TwoFills, "/Pattern <</P1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Cell("/ExtGState <</G 7 0 R>>"), "/G gs 0 0 600 800 re f");
            pdf.Obj(7, "<</Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 8 0 R >> >>");
            pdf.Stream(8, Group, "q 100 0 0 100 100 100 cm /Im1 Do Q");
            pdf.Stream(9, ImageEntries, Pixels);
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void PatternCellTooLongToReadIsEmptied()
    {
        using var document = RedactionKit.Page(TwoFills, "/Pattern <</P1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Cell("/XObject <</Im1 7 0 R>>"), string.Concat(Enumerable.Repeat("n ", 1_000_010)) + "/Im1 Do");
            pdf.Stream(7, ImageEntries, Pixels);
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void SoftMaskWithoutAnSKeyIsEmptied()
    {
        using var document = RedactionKit.Page("/GS1 gs 0 0 600 800 re f 10 10 5 5 re f", "/ExtGState <</GS1 6 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</Type /ExtGState /SMask << /Type /Mask /G 7 0 R >> >>");
            pdf.Stream(7, Group.Replace("9 0 R", "8 0 R"), "q 100 0 0 100 100 100 cm /Im1 Do Q");
            pdf.Stream(8, ImageEntries, Pixels);
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void MeshShadingPatternWithAnotherUseIsEmptied()
    {
        using var document = RedactionKit.Page(TwoFills, "/Pattern <</P1 6 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</PatternType 2 /Shading 7 0 R>>");
            pdf.Stream(7, "/ShadingType 4 /ColorSpace /DeviceGray /BitsPerCoordinate 8 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 600 0 800 0 1]", "ZQXMESHDATAZQXMESHDATA");
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXMESHDATA"));
    }

    [Fact]
    public void PictureOnlyAnEmptiedCellPaintedDoesNotStayInASharedResourceList()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources 9 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources 9 0 R>>");
        pdf.Stream(5, "", "q 60 0 0 60 210 210 cm /Im1 Do Q /Pattern cs /P1 scn 220 220 30 30 re f");
        pdf.Stream(6, "", "/Pattern cs /P1 scn 10 10 20 20 re f");
        pdf.Obj(9, "<</XObject <</Im1 8 0 R>> /Pattern <</P1 10 0 R>>>>");
        pdf.Stream(8, ImageEntries, Pixels);
        pdf.Stream(10, Cell("/XObject <</Im1 8 0 R>>"), "q 50 0 0 50 0 0 cm /Im1 Do Q");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }
}
