using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SanitizeLayerTests
{
    // Layer 5 is off and layer 6 on; 7 is a membership dictionary that follows 5.
    private const string Catalog = "/OCProperties <</OCGs [5 0 R 6 0 R] /D <</OFF [5 0 R] /Order [5 0 R 6 0 R]>>>>";

    private static byte[] Fixture() => OptimizeKit.Build(
        "/OC /L1 BDC 1 0 0 rg 0 0 50 50 re f BT /F1 12 Tf 10 10 Td (HIDDENTEXT) Tj ET EMC " +
        "BT /F1 12 Tf 10 100 Td (VISIBLETEXT) Tj ET " +
        "/OC /L2 BDC BT /F1 12 Tf 10 120 Td (SHOWNLAYER) Tj ET EMC " +
        "/OC /M1 BDC BT /F1 12 Tf 10 140 Td (HIDDENMEMBER) Tj ET EMC " +
        "q /Fm0 Do Q q /Fm1 Do Q q 20 0 0 20 100 100 cm /Im0 Do Q",
        "/Font <</F1 8 0 R>> /Properties <</L1 5 0 R /L2 6 0 R /M1 7 0 R>> /XObject <</Fm0 9 0 R /Fm1 10 0 R /Im0 11 0 R>>",
        pdf =>
        {
            pdf.Obj(5, "<</Type /OCG /Name (MARKERLAYER)>>");
            pdf.Obj(6, "<</Type /OCG /Name (Shown)>>");
            pdf.Obj(7, "<</Type /OCMD /OCGs [5 0 R]>>");
            pdf.Obj(8, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /OC 5 0 R", "BT /F1 12 Tf (HIDDENFORM) Tj ET");
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources <</Font <</F1 8 0 R>> /Properties <</L1 5 0 R>>>>",
                "BT /F1 12 Tf 10 60 Td (INSIDEVISIBLE) Tj ET /OC /L1 BDC BT /F1 12 Tf (INSIDEHIDDEN) Tj ET EMC");
            pdf.Stream(11, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /OC 5 0 R", "H");
        }, catalogExtra: Catalog);

    [Fact]
    public void HiddenLayerContentIsCutOutOfEveryStream()
    {
        byte[] file = Fixture();
        foreach (string text in new[] { "HIDDENTEXT", "HIDDENMEMBER", "HIDDENFORM", "INSIDEHIDDEN", "MARKERLAYER" }) Assert.True(OptimizeKit.Everywhere(file, text));
        using var document = PdfDocument.Open(file);
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        foreach (string text in new[] { "HIDDENTEXT", "HIDDENMEMBER", "HIDDENFORM", "INSIDEHIDDEN", "MARKERLAYER" }) Assert.False(OptimizeKit.Everywhere(result.Bytes, text), text);
        string shown = OptimizeKit.EngineText(result.Bytes);
        Assert.Contains("VISIBLETEXT", shown);
        Assert.Contains("SHOWNLAYER", shown);
        Assert.Contains("INSIDEVISIBLE", shown);
        Assert.Equal(1, SanitizeKit.Count(result.Removed, SanitizeItem.HiddenLayers));
        Assert.Contains("VISIBLETEXT", OptimizeKit.PigText(result.Bytes));
    }

    [Fact]
    public void TheVisibleLayerAndItsGroupSurvive()
    {
        using var document = PdfDocument.Open(Fixture());
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        using var after = PdfDocument.Open(result.Bytes);
        var layers = PdfLayers.Read(after);
        Assert.Single(layers.Layers);
        Assert.Equal("Shown", layers.Layers[0].Name);
        Assert.True(layers.Layers[0].IsOn);
        var operations = ContentParser.Parse(after.Pages[0].Contents());
        Assert.Equal(operations.Count(o => o.Operator is "BDC" or "BMC"), operations.Count(o => o.Operator == "EMC"));
    }

    [Fact]
    public void HiddenLayersStayWhenNotAsked()
    {
        using var document = PdfDocument.Open(Fixture());
        var findings = new PdfSanitizer(document).Scan();
        Assert.Equal(1, SanitizeKit.Count(findings, SanitizeItem.HiddenLayers));
        var result = new PdfSanitizer(document).Run(new SanitizeOptions { HiddenLayers = false });
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "HIDDENTEXT"));
        Assert.Equal(1, SanitizeKit.Count(result.Kept, SanitizeItem.HiddenLayers));
    }

    [Fact]
    public void AnnotationOnAHiddenLayerGoes()
    {
        byte[] file = OptimizeKit.Build("BT /F1 12 Tf (page) Tj ET", "", pdf =>
        {
            pdf.Obj(5, "<</Type /OCG /Name (Hidden)>>");
            pdf.Obj(6, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /OC 5 0 R /Contents (MARKERNOTE)>>");
            pdf.Obj(7, "<</Type /Annot /Subtype /Link /Rect [20 0 30 10] /Contents (kept)>>");
        }, pageExtra: "/Annots [6 0 R 7 0 R]", catalogExtra: "/OCProperties <</OCGs [5 0 R] /D <</BaseState /OFF /ON []>>>>");
        using var document = PdfDocument.Open(file);
        var result = new PdfSanitizer(document).Run(new SanitizeOptions { Comments = false });
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERNOTE"));
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "kept"));
    }
}
