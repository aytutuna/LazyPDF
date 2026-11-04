using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A Type 3 font with anything but plain glyph procedures makes the page a picture; the procedures are looked at once, not once per glyph.
public class RedactGlyphProbeTests
{
    private const string Pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123";
    private const string ImageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8";
    private const string Paints = "1000 0 d0 q 10000 0 0 10000 20000 20000 cm /Im1 Do Q";
    private static readonly PdfRect Over = new(240, 240, 360, 360);

    private static string Type3(string procedures, string names, string resources = "") =>
        $"<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <<{procedures}>> " +
        $"/Encoding <</Type /Encoding /Differences [97 {names}]>> /FirstChar 97 /LastChar {96 + names.Split(' ').Length} /Widths [{string.Join(' ', names.Split(' ').Select(_ => 1000))}] {resources}>>";

    [Fact]
    public void MatrixOnTheProcedureStreamMovesNothing()
    {
        using var document = RedactionKit.Page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>> /XObject <</Im1 8 0 R>>", pdf =>
        {
            pdf.Obj(6, Type3("/a 7 0 R", "/a", "/Resources <</XObject <</Im1 8 0 R>>>>"));
            pdf.Stream(7, "/Matrix [1 0 0 1 900000 0]", Paints);
            pdf.Stream(8, ImageEntries, Pixels);
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Over)], "ZQXPIXELSDATA");
    }

    [Fact]
    public void GlyphOfASecondFontShownByAProcedureMakesThePagePicture()
    {
        using var document = RedactionKit.Page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>>", pdf =>
        {
            pdf.Obj(6, Type3("/a 7 0 R", "/a", "/Resources <</Font <</T2 9 0 R>>>>"));
            pdf.Stream(7, "", "1000 0 d0 BT /T2 1000 Tf (a) Tj ET");
            pdf.Stream(8, ImageEntries, Pixels);
            pdf.Obj(9, Type3("/a 10 0 R", "/a", "/Resources <</XObject <</Im1 8 0 R>>>>"));
            pdf.Stream(10, "", Paints);
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Over)], "ZQXPIXELSDATA");
    }

    [Fact]
    public void ProcedureThatCallsFormsMakesThePagePicture()
    {
        using var document = RedactionKit.Page("BT /T3 10 Tf 50 50 Td (a) Tj ET", "/Font <</T3 6 0 R>>", pdf =>
        {
            pdf.Obj(6, Type3("/a 7 0 R", "/a", "/Resources <</XObject <</N1 9 0 R /Im1 8 0 R>>>>"));
            pdf.Stream(7, "", "1000 0 d0 " + string.Concat(Enumerable.Repeat("/N1 Do ", 12)) + "q 10000 0 0 10000 20000 20000 cm /Im1 Do Q");
            pdf.Stream(8, ImageEntries, Pixels);
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 1 1]", string.Concat(Enumerable.Repeat("n ", 900_000)));
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Over)], "ZQXPIXELSDATA");
    }

    [Fact]
    public void ManyGlyphsOfALongProcedureAreProbedOnce()
    {
        using var document = RedactionKit.Page($"BT /T3 10 Tf 50 50 Td ({new string('a', 100)}) Tj ET", "/Font <</T3 6 0 R>>", pdf =>
        {
            pdf.Obj(6, Type3("/a 7 0 R", "/a"));
            pdf.Stream(7, "", "1000 0 d0 " + string.Concat(Enumerable.Repeat("n ", 100_000)));
        });
        var result = RedactionKit.Apply(document, [RedactionMark.FromRect(0, new PdfRect(500, 40, 550, 70))]);
        Assert.Contains(0, result.Report.Flattened);
    }
}
