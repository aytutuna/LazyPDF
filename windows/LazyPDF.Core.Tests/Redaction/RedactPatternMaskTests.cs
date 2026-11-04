using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Cells of patterns and groups of soft masks are not cut by the marks: with pictures or text they make the page a picture, and fonts nothing shows any more leave with the text.
public class RedactPatternMaskTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private const string Group = "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group << /S /Transparency /CS /DeviceGray >> /Resources <</XObject <</Im1 8 0 R>> /Font <</F1 5 0 R>>>>";
    private const string Subset = "<</Type /Font /Subtype /Type1 /BaseFont /ZQXSubset /FirstChar 65 /LastChar 66 /Widths [500 500] /ToUnicode 8 0 R>>";
    private static readonly PdfRect Hole = new(200, 200, 300, 300);

    private static RedactionResult Redact(PdfDocument document) => RedactionKit.Apply(document, [RedactionMark.FromRect(0, Hole)]);

    private static PdfDocument Masked(string content) =>
        RedactionKit.Page(content, "/ExtGState <</GS1 6 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 7 0 R >> >>");
            pdf.Stream(7, Group, "q 100 0 0 100 100 100 cm /Im1 Do Q BT /F1 12 Tf 200 200 Td (ZQXGROUPTEXT) Tj ET");
            pdf.Stream(8, ImageEntries, Pixels);
        });

    [Fact]
    public void MaskedFillThatMeetsAMarkMakesThePagePicture()
    {
        using var document = Masked("/GS1 gs 0 0 600 800 re f");
        RedactionKit.AssertFlattened(document, Hole, "ZQXPIXELSDATA", "ZQXGROUPTEXT");
    }

    [Fact]
    public void MaskAlsoUsedElsewhereIsEmptiedNotKeptWhole()
    {
        using var document = Masked("/GS1 gs 0 0 600 800 re f 10 10 5 5 re f");
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXGROUPTEXT"));
    }

    [Fact]
    public void PatternCellAlsoUsedElsewhereIsEmptiedNotKeptWhole()
    {
        using var document = RedactionKit.Page("/Pattern cs /P1 scn 0 0 600 800 re f 10 10 5 5 re f", "/Pattern <</P1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 600 800] /XStep 600 /YStep 800 /Resources <</XObject <</Im1 7 0 R>>>>", "q 600 0 0 800 0 0 cm /Im1 Do Q");
            pdf.Stream(7, ImageEntries, Pixels);
        });
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
    }

    [Fact]
    public void PatternFilledTextKeepsNoCellTextWhenOneWordIsOutsideTheMark()
    {
        using var document = RedactionKit.Page("/Pattern cs /P1 scn BT /F1 12 Tf 210 250 Td (inside) Tj 0 300 Td (outside) Tj ET", "/Pattern <</P1 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 50 50] /XStep 50 /YStep 50 /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 5 5 Td (ZQXCELLTEXT) Tj ET"));
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXCELLTEXT"));
    }

    [Fact]
    public void PatternOfPlainShapesStaysForOtherUses()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 150 150 Td (ZQXWORD) Tj ET /Pattern cs /P1 scn 400 400 50 50 re f", "/Pattern <</P1 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <<>>", "0 0 5 5 re f"));
        var result = new PdfRedactor(document).Apply([RedactionKit.MarkOf(document, 0, "ZQXWORD")]);
        Assert.Empty(result.Report.Flattened);
        using var output = RedactionKit.Open(result);
        var cell = output.Dict(output.Dict(output.Pages[0].Dictionary, "Resources"), "Pattern")?["P1"];
        Assert.True(output.Resolve(cell) is PdfStream s && System.Text.Encoding.Latin1.GetString(output.Data(s)).Contains("5 5 re"));
    }

    [Fact]
    public void AxialShadingPatternUnderTheMarkIsRemovedFromThatUse()
    {
        using var document = RedactionKit.Page("/Pattern cs /P1 scn 150 150 200 200 re f", "/Pattern <</P1 6 0 R>>", pdf =>
            pdf.Obj(6, "<</PatternType 2 /Shading <</ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function <</FunctionType 2 /Domain [0 1] /N 1>>>>>>"));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Hole)]);
        Assert.Empty(result.Report.Flattened);
        Assert.Equal(1, result.Report.Paths);
    }

    [Fact]
    public void MeshShadingPatternUnderTheMarkMakesThePagePicture()
    {
        using var document = RedactionKit.Page("/Pattern cs /P1 scn 150 150 200 200 re f", "/Pattern <</P1 6 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</PatternType 2 /Shading 7 0 R>>");
            pdf.Stream(7, "/ShadingType 4 /ColorSpace /DeviceGray /BitsPerCoordinate 8 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 255 0 255 0 1]", "ZQXMESHDATA");
        });
        RedactionKit.AssertFlattened(document, Hole, "ZQXMESHDATA");
    }

    [Fact]
    public void FontStillUsedByAMaskGroupKeepsItsResource()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (secret) Tj ET /GS1 gs 400 400 50 50 re f", "/ExtGState <</GS1 6 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 7 0 R >> >>");
            pdf.Stream(7, Group, "BT /F1 12 Tf 410 410 Td (mask) Tj ET");
            pdf.Stream(8, ImageEntries, Pixels);
        });
        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, new PdfRect(90, 690, 200, 720))]);
        using var output = RedactionKit.Open(result);
        var group = output.ObjectNumbers.Select(output.Get).OfType<PdfStream>().Single(s => output.Dict(s.Dictionary, "Group") is not null);
        Assert.True(output.Dict(output.Dict(group.Dictionary, "Resources"), "Font")?.ContainsKey("F1"));
    }

    [Fact]
    public void FontListedInTheFormDefaultsIsDropped()
    {
        using var document = RedactionKit.Page("BT /F2 12 Tf 50 100 Td (AB) Tj ET", "/Font <</F1 5 0 R /F2 6 0 R>>", pdf =>
        {
            pdf.Obj(5, RedactionKit.Helvetica);
            pdf.Obj(6, Subset);
            pdf.Stream(8, "", "ZQXTOUNICODE");
        });
        PdfForm.Read(document).AddField(new FieldSpec(FieldKind.Text, "f", 0, new PdfRect(300, 400, 400, 420)));
        var form = document.Dict(document.Catalog, "AcroForm")!;
        form["DR"] = new PdfDictionary { ["Font"] = new PdfDictionary { ["F2"] = new PdfReference(6, 0) } };
        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, new PdfRect(40, 90, 100, 120))]);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXTOUNICODE"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSubset"));
    }

    [Fact]
    public void FontSelectedByAGraphicsStateMakesThePagePicture()
    {
        using var document = ContentTestPdf.Page("/GS1 gs BT 50 100 Td (AB) Tj ET", "/ExtGState <</GS1 7 0 R>>", pdf =>
        {
            pdf.Obj(6, Subset);
            pdf.Obj(7, "<</Type /ExtGState /Font [6 0 R 12]>>");
            pdf.Stream(8, "", "ZQXTOUNICODE");
        });
        RedactionKit.AssertFlattened(document, new PdfRect(40, 90, 100, 120), "ZQXTOUNICODE", "ZQXSubset");
    }

    [Fact]
    public void FontOfTheRemovedTextLeavesTheResourcesWithItsSelection()
    {
        using var document = ContentTestPdf.Page("BT /F1 12 Tf 50 700 Td (visible) Tj /F2 12 Tf 0 -200 Td (AB) Tj ET", "/Font <</F1 5 0 R /F2 6 0 R>>", pdf =>
        {
            pdf.Obj(5, RedactionKit.Helvetica);
            pdf.Obj(6, Subset);
            pdf.Stream(8, "", "ZQXTOUNICODE");
        });
        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, new PdfRect(40, 490, 100, 520))]);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSubset"));
        Assert.False(output.Dict(output.Dict(output.Pages[0].Dictionary, "Resources"), "Font")?.ContainsKey("F2"));
    }
}
