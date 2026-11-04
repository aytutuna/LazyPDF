using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// The ways back into a form besides Do, each of which makes the page a picture: a font chosen by a graphics state, the mask of a shading pattern, a font name with a stray operand.
public class RedactReachRouteTests
{
    private static readonly PdfRect Near = new(90, 90, 200, 120);

    private const string Shows = "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET";
    private const string Type3 = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</b 9 0 R>> " +
        "/Encoding <</Type /Encoding /Differences [98 /b]>> /FirstChar 98 /LastChar 98 /Widths [1000] /Resources <</XObject <</Fm 6 0 R>>>>>>";

    private static string Form(string resources) =>
        $"/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> {resources}>>";

    private static void AssertGone(PdfDocument document) =>
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXCYCLE");

    [Fact]
    public void FormReachedAgainThroughAFontOfAGraphicsStateIsCut()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Form("/ExtGState <</G 7 0 R>>"), Shows + " /G gs BT 300 300 Td (b) Tj ET");
            pdf.Obj(7, "<</Type /ExtGState /Font [8 0 R 12]>>");
            pdf.Obj(8, Type3);
            pdf.Stream(9, "", "1000 0 d0 /Fm Do");
        });
        AssertGone(document);
    }

    [Fact]
    public void FormReachedAgainThroughTheMaskOfAShadingPatternIsCut()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Form("/Pattern <</SP 7 0 R>>"), Shows + " /Pattern cs /SP scn 300 300 5 5 re f");
            pdf.Obj(7, "<</PatternType 2 /Shading <</ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 1 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1>>>> " +
                "/ExtGState <</SMask <</Type /Mask /S /Alpha /G 8 0 R>>>>>>");
            pdf.Stream(8, Form("/XObject <</Fm 6 0 R>>") + " /Group <</S /Transparency>>", "/Fm Do");
        });
        AssertGone(document);
    }

    [Fact]
    public void FormReachedAgainThroughAFontNamedWithAStrayOperandIsCut()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Form("").Replace("/Font <</F1 5 0 R>>", "/Font <</F1 5 0 R /T3 8 0 R>>"), Shows + " BT /Junk /T3 12 Tf 300 300 Td (b) Tj ET");
            pdf.Obj(8, Type3);
            pdf.Stream(9, "", "1000 0 d0 /Fm Do");
        });
        AssertGone(document);
    }
}
