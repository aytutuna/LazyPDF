using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Content that a viewer may read differently from the parser becomes a picture, since what the scan did not see is never cut.
public class RedactInlineEndTests
{
    private const string Image = "q BI /W 1 /H 1 /BPC 8 /CS /G /F /AHx ID ";
    private const string Shows = " Q BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET ";
    private static readonly PdfRect Near = new(90, 90, 200, 120);

    private static void AssertFlat(string content)
    {
        using var document = RedactionKit.Page(content);
        RedactionKit.AssertFlattened(document, [RedactionMark.FromRect(0, Near)], "ZQXCYCLE");
    }

    [Fact]
    public void EndRightAfterTheFilterDataFlattensThePage() =>
        AssertFlat(Image + "00>EI" + Shows + Image + "00> EI Q");

    [Fact]
    public void EndFollowedByACommentFlattensThePage() =>
        AssertFlat(Image + "00> EI%ÿ\n" + Shows + Image + "00> EI Q");

    [Theory]
    [InlineData("BT /F1 12 Tf 100 100 Td /ZQXCYCLE Tj ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td (ZQXCYCLE) TJ ET")]
    [InlineData("BT /F1 12 Tf 100 100 Td Tj ET")]
    public void ShowOperatorWithoutTheOperandItReadsFlattensThePage(string content) => AssertFlat(content);
}
