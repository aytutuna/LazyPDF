using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Cells of patterns and groups of soft masks are not cut by the marks, so they go when they carry pictures or text.
public class RedactPatternMaskTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private const string Group = "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group << /S /Transparency /CS /DeviceGray >> /Resources <</XObject <</Im1 8 0 R>> /Font <</F1 5 0 R>>>>";
    private const string Subset = "<</Type /Font /Subtype /Type1 /BaseFont /ZQXSubset /FirstChar 65 /LastChar 66 /Widths [500 500] /ToUnicode 8 0 R>>";
    private static readonly PdfRect Hole = new(200, 200, 300, 300);

    private static RedactionResult Redact(PdfDocument document) => new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Hole)]);

    private static PdfDocument Masked(string content) =>
        RedactionKit.Page(content, "/ExtGState <</GS1 6 0 R>>", pdf =>
        {
            pdf.Obj(6, "<</Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 7 0 R >> >>");
            pdf.Stream(7, Group, "q 100 0 0 100 100 100 cm /Im1 Do Q BT /F1 12 Tf 200 200 Td (ZQXGROUPTEXT) Tj ET");
            pdf.Stream(8, ImageEntries, Pixels);
        });

    [Fact]
    public void MaskedFillThatMeetsAMarkTakesItsPictureGroupWithIt()
    {
        using var document = Masked("/GS1 gs 0 0 600 800 re f");
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPIXELSDATA"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXGROUPTEXT"));
        Assert.Equal(1, result.Report.Paths);
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
        using var document = RedactionKit.Page("/Pattern cs /P1 scn 150 150 200 200 re f 400 400 50 50 re f", "/Pattern <</P1 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <<>>", "0 0 5 5 re f"));
        var result = Redact(document);
        using var output = RedactionKit.Open(result);
        var cell = output.Dict(output.Dict(output.Pages[0].Dictionary, "Resources"), "Pattern")?["P1"];
        Assert.True(output.Resolve(cell) is PdfStream s && System.Text.Encoding.Latin1.GetString(output.Data(s)).Contains("5 5 re"));
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
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(90, 690, 200, 720))]);
        using var output = RedactionKit.Open(result);
        var group = output.ObjectNumbers.Select(output.Get).OfType<PdfStream>().Single(s => output.Dict(s.Dictionary, "Group") is not null);
        Assert.True(output.Dict(output.Dict(group.Dictionary, "Resources"), "Font")?.ContainsKey("F1"));
    }

    [Fact]
    public void ImageStillPaintedByAType3GlyphKeepsItsResource()
    {
        const string Font = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.1 0 0 0.1 0 0] /CharProcs <</a 9 0 R>> /Encoding <</Type /Encoding /Differences [97 /a]>> " +
                            "/FirstChar 97 /LastChar 97 /Widths [10] /Resources <</XObject <</Im1 8 0 R>>>>>>";
        using var document = RedactionKit.Page("q 160 0 0 160 100 100 cm /Im1 Do Q BT /F3 12 Tf 400 400 Td (a) Tj ET", "/XObject <</Im1 8 0 R>> /Font <</F3 6 0 R>>", pdf =>
        {
            pdf.Obj(6, Font);
            pdf.Stream(8, ImageEntries, Pixels);
            pdf.Stream(9, "", "10 0 d0 q 8 0 0 8 0 0 cm /Im1 Do Q");
        });
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(100, 220, 140, 260))]);
        using var output = RedactionKit.Open(result);
        var font = output.ObjectNumbers.Select(output.Get).OfType<PdfDictionary>().Single(d => output.Name(d, "Subtype") == "Type3");
        Assert.True(output.Dict(output.Dict(font, "Resources"), "XObject")?.ContainsKey("Im1"));
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
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(40, 90, 100, 120))]);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXTOUNICODE"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSubset"));
    }

    [Fact]
    public void FontSelectedByAGraphicsStateIsDropped()
    {
        using var document = ContentTestPdf.Page("/GS1 gs BT 50 100 Td (AB) Tj ET", "/ExtGState <</GS1 7 0 R>>", pdf =>
        {
            pdf.Obj(6, Subset);
            pdf.Obj(7, "<</Type /ExtGState /Font [6 0 R 12]>>");
            pdf.Stream(8, "", "ZQXTOUNICODE");
        });
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(40, 90, 100, 120))]);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXTOUNICODE"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSubset"));
    }

    [Fact]
    public void DroppedFontLeavesAResourceTheTextOperatorStillNames()
    {
        using var document = ContentTestPdf.Page("BT /F1 12 Tf 50 700 Td (visible) Tj /F2 12 Tf 0 -200 Td (AB) Tj ET", "/Font <</F1 5 0 R /F2 6 0 R>>", pdf =>
        {
            pdf.Obj(5, RedactionKit.Helvetica);
            pdf.Obj(6, Subset);
            pdf.Stream(8, "", "ZQXTOUNICODE");
        });
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(40, 490, 100, 520))]);
        using var output = RedactionKit.Open(result);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSubset"));
        Assert.True(output.Dict(output.Dict(output.Pages[0].Dictionary, "Resources"), "Font")?.ContainsKey("F2"));
    }
}
