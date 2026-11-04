using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAScanTests
{
    private const string Helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>";
    private const string Courier = "<</Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding>>";
    private const string Cell = "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <</Font <</F2 12 0 R>>>>";

    private static bool Reports(byte[] file, string clause, string where) => StandardsKit.Check(file).Issues.Any(i => i.Clause == clause && i.Where == where);

    [Theory]
    [InlineData("BT /F1 12 Tf 20 20 Td (A) Tj ET")]
    [InlineData("/Im Do")]
    public void AFontInATilingCellIsFoundWhenTextOrAMaskIsPaintedWithIt(string painting)
    {
        byte[] file = StandardsKit.Compliant(content: "/Pattern cs /P scn " + painting, resources: "/Font <</F1 11 0 R>> /Pattern <</P 9 0 R>> /XObject <</Im 10 0 R>>", extra: pdf =>
        {
            pdf.Stream(9, Cell, "BT /F2 12 Tf (A) Tj ET");
            pdf.Stream(10, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 1 /ImageMask true", " ");
            pdf.Obj(11, Helvetica);
            pdf.Obj(12, Courier);
        });
        Assert.True(Reports(file, "6.2.11.4.1", "Font Courier"));
    }

    [Fact]
    public void AFontInATilingCellIsFoundWhenAPathIsPaintedWithIt()
    {
        byte[] file = StandardsKit.Compliant(content: "/Pattern cs /P scn 0 0 10 10 re f", resources: "/Pattern <</P 9 0 R>>", extra: pdf =>
        {
            pdf.Stream(9, Cell, "BT /F2 12 Tf (A) Tj ET");
            pdf.Obj(12, Courier);
        });
        Assert.True(Reports(file, "6.2.11.4.1", "Font Courier"));
    }

    private const string Type3 = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</a 11 0 R /b 13 0 R>> " +
        "/Encoding <</Type /Encoding /Differences [97 /a /b]>> /FirstChar 97 /LastChar 98 /Widths [500 500] /Resources <<{0}>>>>";

    private static byte[] Glyphs(string shown, string procedure, string resources) => StandardsKit.Compliant(content: $"BT /F1 12 Tf 20 20 Td ({shown}) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: pdf =>
    {
        pdf.Obj(9, string.Format(Type3, resources));
        pdf.Stream(11, "", "500 0 d0");
        pdf.Stream(13, "", procedure);
        pdf.Stream(12, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceCMYK", "    ");
    });

    [Theory]
    [InlineData("500 0 d0 /Sh sh", "/Shading <</Sh <</ShadingType 2 /ColorSpace /DeviceCMYK /Coords [0 0 1 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [1 1 1 1] /N 1>>>>>>")]
    [InlineData("500 0 d0 /C cs 0 sc 0 0 5 5 re f", "/ColorSpace <</C [/Indexed /DeviceCMYK 0 <00000000>]>>")]
    [InlineData("500 0 d0 /Im Do", "/XObject <</Im 12 0 R>>")]
    public void ADeviceSpaceUsedInAGlyphProcedureCountsAsUsed(string procedure, string resources)
    {
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(Glyphs("b", procedure, resources)));
    }

    [Fact]
    public void AGlyphThatIsNeverShownDoesNotPaint()
    {
        const string resources = "/XObject <</Im 12 0 R>>";
        Assert.DoesNotContain("6.2.4.3", StandardsKit.Clauses(Glyphs("a", "500 0 d0 /Im Do", resources)));
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(Glyphs("ab", "500 0 d0 /Im Do", resources)));
    }

    private static byte[] Masked(string content) => StandardsKit.Compliant(content: content, resources: "/ExtGState <</GS0 <</SMask <</S /Luminosity /G 9 0 R>>>>>>", extra: pdf =>
    {
        pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 300] /Group <</S /Transparency /CS /DeviceGray>> /Resources <</XObject <</Im 12 0 R>>>>", "/Im Do");
        pdf.Stream(12, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceCMYK", "    ");
    });

    [Fact]
    public void ASoftMaskNobodyAppliesPaintsNothing()
    {
        Assert.DoesNotContain("6.2.4.3", StandardsKit.Clauses(Masked("0 0 1 rg 20 20 100 100 re f")));
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(Masked("/GS0 gs 0 0 1 rg 20 20 100 100 re f")));
    }

    [Fact]
    public void ASoftMaskGroupIsHeldToTheContentRulesAndItsNestedMasksAreFollowed()
    {
        byte[] file = StandardsKit.Compliant(content: "/GS0 gs 0 0 1 rg 20 20 100 100 re f", resources: "/ExtGState <</GS0 <</SMask <</S /Luminosity /G 9 0 R>>>>>>", extra: pdf =>
        {
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 300] /Group <</S /Transparency /CS /DeviceGray>> " +
                "/Resources <</ExtGState <</GS1 <</SMask <</S /Luminosity /G 10 0 R>>>>>>>>", "/GS1 gs <ABC> pop bogus");
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 200 300] /Group <</S /Transparency /CS /DeviceGray>> /Resources <</Font <</F1 11 0 R>>>>", "BT /F1 12 Tf (A) Tj ET");
            pdf.Obj(11, Helvetica);
        });
        var issues = StandardsKit.Check(file).Issues;
        Assert.Contains(issues, i => i.Clause == "6.2.2" && i.Message == PdfAText.UnknownOperator("pop"));
        Assert.Contains(issues, i => i.Clause == "6.1.6");
        Assert.Contains(issues, i => i.Clause == "6.2.11.4.1" && i.Where == "Font Helvetica");
    }
}
