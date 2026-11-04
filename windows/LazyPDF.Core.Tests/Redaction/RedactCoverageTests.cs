using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactCoverageTests
{
    private const string FormEntries = "/Type /XObject /Subtype /Form /BBox [0 0 600 800]";
    private static readonly PdfRect Mark = new(40, 690, 300, 720);

    // Forms 1 to depth, each painting the next; the last shows the text.
    private static PdfDocument Chain(int depth) =>
        RedactionKit.Page("/Fm1 Do", "/XObject <</Fm1 6 0 R>>", pdf =>
        {
            for (int i = 1; i < depth; i++)
            {
                pdf.Stream(5 + i, $"{FormEntries} /Resources <</XObject <</Fm{i + 1} {6 + i} 0 R>>>>", $"/Fm{i + 1} Do");
            }
            pdf.Stream(5 + depth, $"{FormEntries} /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 50 700 Td (secret) Tj ET");
        });

    [Fact]
    public void FormsNestedBeyondTheDepthTheWalkerEntersGoWhenTheyReachTheMark()
    {
        using var document = Chain(22);
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Mark)]);
        Assert.True(result.Verification.IsClean);
        Assert.False(RedactionKit.Holds(result.Bytes, "secret"));
        Assert.Equal(1, result.Report.Paths);
    }

    [Fact]
    public void FormsWithinTheDepthAreRedacted()
    {
        using var document = Chain(10);
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Mark)]);
        Assert.Equal(6, result.Report.Glyphs);
        Assert.True(result.Verification.IsClean);
    }

    private static PdfDocument Unreadable(string box) =>
        RedactionKit.Page("/Fm1 Do BT /F1 12 Tf 50 700 Td (secret) Tj ET", "/XObject <</Fm1 6 0 R>>",
            pdf => pdf.Stream(6, $"/Type /XObject /Subtype /Form /BBox {box} /Filter /FlateDecode", "this is not deflate data"));

    [Fact]
    public void FormThatCannotBeReadGoesWhenItReachesTheMark()
    {
        using var document = Unreadable("[0 0 600 800]");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Mark)]);
        Assert.True(result.Verification.IsClean);
        Assert.False(RedactionKit.Holds(result.Bytes, "this is not deflate data"));
        Assert.Equal(6, result.Report.Glyphs);
    }

    [Fact]
    public void FormThatCannotBeReadStaysWhenItIsFarFromTheMark()
    {
        using var document = Unreadable("[0 0 10 10]");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Mark)]);
        Assert.True(RedactionKit.Holds(result.Bytes, "this is not deflate data"));
        Assert.Equal(0, result.Report.Paths);
    }

    [Fact]
    public void VerifyDoesNotCallAPageItCannotFollowClean()
    {
        using var document = Chain(22);
        var verification = PdfRedactor.Verify(document.SaveRewrite(), [RedactionMark.FromRect(0, Mark)], []);
        Assert.False(verification.IsClean);
        Assert.Contains("Page 1 could not be followed", Assert.Single(verification.Problems));
    }

    [Fact]
    public void VerifyChecksEveryRemovedStringNotTheFirstFiveHundred()
    {
        using var document = RedactionKit.Page("/Span <</ActualText (ZQXLASTNEEDLE)>> BDC EMC");
        var removed = Enumerable.Range(0, 600).Select(i => $"needle number {i}").Append("ZQXLASTNEEDLE").ToList();
        var verification = PdfRedactor.Verify(document.SaveRewrite(), [], removed);
        Assert.False(verification.IsClean);
    }

    [Fact]
    public void VerifySaysSoWhenThereAreMoreStringsThanItChecks()
    {
        using var document = RedactionKit.Page("BT ET");
        var removed = Enumerable.Range(0, 50_001).Select(i => $"needle number {i}").ToList();
        var verification = PdfRedactor.Verify(document.SaveRewrite(), [], removed);
        Assert.Contains(verification.Problems, p => p.StartsWith("Not every removed string"));
    }
}
