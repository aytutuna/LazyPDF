using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Descriptions, attachments and page keys that stay behind when their content is cut, and the picture a flattened page becomes.
public class RedactLeftoverKeysTests
{
    private static readonly PdfRect Over = RedactionFiles.Over;

    [Theory]
    [InlineData("/Note /P0 DP /Span <</MCID 0>> BDC", "/Properties <</P0 6 0 R>>")]
    [InlineData("/Span <</MCID 0 /X <</Alt (ZQXDESC)>>>> BDC", "")]
    [InlineData("/Span <</MCID 0 /Alt (ZQXDESC)>> BDC", "")]
    public void DescriptionsOfCutTextGoWhateverHoldsThem(string open, string resources)
    {
        using var document = RedactionFiles.Open(open + " " + RedactionFiles.Word + " EMC", resources, pdf => pdf.Obj(6, "<</ActualText (ZQXDESC)>>"));
        var result = RedactionFiles.Apply(document, RedactionMark.FromRect(0, Over));
        RedactionFiles.Gone(result, "ZQXDESC", "ZQXSECRET");
    }

    private static PdfDocument Tagged(string element, Action<TestPdf>? more = null) =>
        RedactionFiles.Open("/Figure <</MCID 0>> BDC " + RedactionFiles.Picture + " EMC /P <</MCID 1>> BDC BT /F1 12 Tf 400 600 Td (kept) Tj ET EMC", "/XObject <</Im1 6 0 R>>", pdf =>
        {
            RedactionFiles.Image(pdf, 6);
            pdf.Obj(10, "<</Type /StructTreeRoot /K 11 0 R>>");
            pdf.Obj(11, element);
            more?.Invoke(pdf);
        }, pageExtra: "/StructParents 0", catalogExtra: "/StructTreeRoot 10 0 R");

    [Fact]
    public void ElementWithoutAPageLosesItsDescription()
    {
        using var document = Tagged("<</Type /StructElem /S /Figure /P 10 0 R /Alt (ZQXALTTEXT) /K 0>>");
        RedactionFiles.Gone(RedactionFiles.Apply(document, RedactionMark.FromRect(0, new PdfRect(90, 90, 250, 250))), "ZQXALTTEXT");
    }

    [Fact]
    public void ElementThatStaysLosesItsAssociatedFiles()
    {
        using var document = Tagged("<</Type /StructElem /S /Figure /P 10 0 R /Pg 30 0 R /K [0 1] /AF [12 0 R]>>", pdf =>
        {
            pdf.Obj(12, "<</Type /Filespec /F (s.txt) /EF <</F 13 0 R>>>>");
            pdf.Stream(13, "/Type /EmbeddedFile", "ZQXSOURCEDATA");
        });
        RedactionFiles.Gone(RedactionFiles.Apply(document, RedactionMark.FromRect(0, new PdfRect(90, 90, 250, 250))), "ZQXSOURCEDATA");
    }

    [Fact]
    public void PrivatePageKeysAreNotKept()
    {
        using var document = RedactionFiles.Open(RedactionFiles.Word, pageExtra: "/Private <</Note (ZQXNOTE)>> /Thumb 6 0 R", more: pdf => pdf.Stream(6, "", "ZQXTHUMB"));
        RedactionFiles.Gone(RedactionFiles.Apply(document, RedactionMark.FromRect(0, Over)), "ZQXNOTE", "ZQXTHUMB");
    }

    [Fact]
    public void FlatteningOnePageLeavesTheWidgetOfAnUnmarkedPageAndItsField()
    {
        using var document = RedactionFiles.Open(["% not whole\n" + RedactionFiles.Word, "BT ET"], more: pdf =>
        {
            pdf.Obj(10, "<</FT /Tx /T (date) /V (Monday) /Kids [11 0 R 12 0 R]>>");
            pdf.Obj(11, "<</Type /Annot /Subtype /Widget /Parent 10 0 R /Rect [400 600 450 620] /P 30 0 R>>");
            pdf.Obj(12, "<</Type /Annot /Subtype /Widget /Parent 10 0 R /Rect [400 600 450 620] /P 32 0 R>>");
        }, pageExtras: ["/Annots [11 0 R]", "/Annots [12 0 R]"], catalogExtra: "/AcroForm <</Fields [10 0 R]>>");
        var result = RedactionFiles.Apply(document, RedactionMark.FromRect(0, Over));
        Assert.Contains(0, result.Report.Flattened);
        using var output = RedactionKit.Reopen(result.Bytes);
        Assert.Single(PdfAnnotations.Read(output, output.Pages[1]));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    private sealed class SquareRenderer : IPageRenderer
    {
        public PdfRgbaImage? Render(int pageIndex, double dpi) => new(100, 100, new byte[100 * 100 * 4]);
    }

    [Fact]
    public void PictureDrawnInAnotherShapeThanThePageIsRefused()
    {
        using var document = RedactionFiles.Open("% not whole\n" + RedactionFiles.Word);
        var options = new RedactionOptions { Renderer = new SquareRenderer(), FlattenDpi = 24 };
        var error = Assert.Throws<InvalidOperationException>(() => new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Over)], options));
        Assert.Equal(RedactionText.NotDrawn(0), error.Message);
    }
}
