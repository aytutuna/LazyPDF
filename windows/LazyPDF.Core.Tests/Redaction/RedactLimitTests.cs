using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Where the interpreter drops state without saying so, the scan cannot tell where things are.
public class RedactLimitTests
{
    private const string Text = "BT /F1 12 Tf 50 700 Td (ZQXQSECRET) Tj ET";
    private static readonly PdfRect Mark = new(40, 690, 200, 720);
    private static readonly PdfRect Moved = new(340, 990, 500, 1020);

    private static string DeepStack => string.Concat(Enumerable.Repeat("q ", 300)) + "1 0 0 1 300 300 cm Q " + Text;

    [Fact]
    public void PageThatOpensMoreThanTheStackHoldsIsRefused()
    {
        using var document = RedactionKit.Page(DeepStack);
        Assert.Throws<InvalidOperationException>(() => new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Moved)]));
    }

    [Fact]
    public void PathLongerThanTheInterpreterKeepsIsRefused()
    {
        string path = string.Concat(Enumerable.Repeat("0 0 1 1 re ", 200_001));
        using var document = RedactionKit.Page(path + "60 700 m 200 700 l S");
        Assert.Throws<InvalidOperationException>(() => new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Mark)]));
    }

    [Fact]
    public void FormThatOpensMoreThanTheStackHoldsGoesWholeWhenItMeetsAMark()
    {
        using var document = RedactionKit.Page("/Fm1 Do", "/XObject <</Fm1 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", DeepStack));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Mark)]);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXQSECRET"));
    }

    [Fact]
    public void VerifyReportsAMarkedPageItCannotFollow()
    {
        using var document = RedactionKit.Page(DeepStack);
        var verification = PdfRedactor.Verify(document.SaveRewrite(), [RedactionMark.FromRect(0, Moved)], []);
        Assert.False(verification.IsClean);
    }

    [Fact]
    public void ShowOperatorWithMoreOperandsThanTheParserKeepsIsRefused()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 50 700 Td " + string.Concat(Enumerable.Repeat("(a) ", 520)) + "(iiiiZQXOPERAND) Tj ET");
        Assert.Throws<InvalidOperationException>(() => new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Mark)]));
    }

    [Fact]
    public void MarkedContentNestedDeeperThanTheInterpreterReportsIsRefused()
    {
        string content = string.Concat(Enumerable.Repeat("/X BMC ", 1030)) + "/Span <</Alt (ZQXDESCR)>> BDC " + Text + " EMC " + string.Concat(Enumerable.Repeat("EMC ", 1030));
        using var document = RedactionKit.Page(content);
        Assert.Throws<InvalidOperationException>(() => new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Mark)]));
    }
}
