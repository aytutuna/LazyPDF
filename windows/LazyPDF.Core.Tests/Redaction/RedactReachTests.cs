using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// What the interpreter does not enter is not looked at, and a copy of the form would still name it: loops that depend on
// where a name is looked up, loops through other kinds of content, marked content nested over several streams. Each makes the
// page a picture.
public class RedactReachTests
{
    private static readonly PdfRect Near = new(90, 90, 200, 120);

    private static string Form(string resources, string box = "[0 0 600 800]") =>
        $"/Type /XObject /Subtype /Form /BBox {box} /Resources <</Font <</F1 5 0 R>> {resources}>>";

    private const string Away = "[300 300 400 400]";
    private const string Shows = "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET";

    private static RedactionResult Redact(PdfDocument document) => RedactionKit.Apply(document, [RedactionMark.FromRect(0, Near)]);

    private static void AssertGone(RedactionResult result)
    {
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXCYCLE"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void FormEnteredAgainUnderAnotherScopeIsCut()
    {
        using var document = RedactionKit.Page("/Fm Do /G Do", "/XObject <</Fm 6 0 R /G 7 0 R /N 8 0 R>>", pdf =>
        {
            pdf.Stream(6, Form(""), Shows + " q 1 0 0 1 5000 0 cm /N Do Q");
            pdf.Stream(7, Form("/XObject <</Fm 6 0 R /N 6 0 R>>"), "/Fm Do");
            pdf.Stream(8, Form(""), "");
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXCYCLE");
    }

    [Fact]
    public void LoopThatOnlyOnePathThroughASharedFormClosesIsFound()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Form("/XObject <</A 7 0 R /B 8 0 R>>"), Shows + " /A Do /B Do");
            pdf.Stream(7, Form("/XObject <</X 9 0 R /N 10 0 R>>", Away), "/X Do");
            pdf.Stream(8, Form("/XObject <</X 9 0 R /N 6 0 R>>", Away), "/X Do");
            pdf.Stream(9, Form("", Away), "/N Do");
            pdf.Stream(10, Form("", Away), "");
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXCYCLE");
    }

    [Fact]
    public void FormReachedAgainThroughATilingPatternIsCut()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Form("/Pattern <</P1 7 0 R>>"), Shows + " /Pattern cs /P1 scn 300 300 5 5 re f");
            pdf.Stream(7, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <</XObject <</Fm 6 0 R>>>>", "/Fm Do");
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXCYCLE");
    }

    [Fact]
    public void FormReachedAgainThroughASoftMaskGroupIsCut()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Form("/ExtGState <</G 7 0 R>>"), Shows + " /G gs 300 300 5 5 re f");
            pdf.Obj(7, "<</Type /ExtGState /SMask <</Type /Mask /S /Alpha /G 8 0 R>>>>");
            pdf.Stream(8, Form("/XObject <</Fm 6 0 R>>") + " /Group <</S /Transparency>>", "/Fm Do");
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXCYCLE");
    }

    [Fact]
    public void FormReachedAgainThroughAType3ProcedureIsCut()
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
        {
            pdf.Stream(6, Form("").Replace("/Font <</F1 5 0 R>>", "/Font <</F1 5 0 R /T3 7 0 R>>"), Shows + " BT /T3 12 Tf 300 300 Td (b) Tj ET");
            pdf.Obj(7, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</b 8 0 R>> " +
                "/Encoding <</Type /Encoding /Differences [98 /b]>> /FirstChar 98 /LastChar 98 /Widths [1000] /Resources <</XObject <</Fm 6 0 R>>>>>>");
            pdf.Stream(8, "", "1000 0 d0 /Fm Do");
        });
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXCYCLE");
    }

    [Theory]
    [InlineData("[250 250 400 400]")]
    [InlineData("[0 0 0 0]")]
    public void CyclicFormWhoseBoxMissesTheMarkIsCutWhereTheTextIs(string box)
    {
        using var document = RedactionKit.Page("/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
            pdf.Stream(6, Form("/XObject <</Fm 6 0 R>>", box), Shows + " q 1 0 0 1 5000 0 cm /Fm Do Q"));
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXCYCLE");
    }

    [Fact]
    public void MarkedContentOpenedAcrossTheStreamsPastTheLimitIsNotFollowed()
    {
        string outer = string.Concat(Enumerable.Repeat("/X BMC ", 1000));
        string inner = string.Concat(Enumerable.Repeat("/X BMC ", 40));
        using var document = RedactionKit.Page(outer + "/Fm Do", "/XObject <</Fm 6 0 R>>", pdf =>
            pdf.Stream(6, Form(""), inner + "/Span <</Alt (ZQXDESCR)>> BDC BT /F1 12 Tf 100 100 Td (xyzw) Tj ET EMC"));
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXDESCR");
    }

    [Fact]
    public void InlineImageWhoseEndTheParserMayHaveMissedMakesThePagePicture()
    {
        using var document = RedactionKit.Page("q BI /W 1 /H 1 /BPC 8 /CS /G /F /AHx ID 00> EI Q BT (Müller) Tj /F1 12 Tf 100 100 Td (ZQXAFTER) Tj ET");
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXAFTER");
    }

    [Fact]
    public void FilteredInlineImageMakesThePagePicture()
    {
        using var document = RedactionKit.Page("q BI /W 1 /H 1 /BPC 8 /CS /G /F /AHx ID 00> EI Q BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET");
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, new PdfRect(90, 90, 200, 120))], "ZQXCYCLE");
    }
}
