using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Names carry text too: UTF-8 in their bytes, and font names that are not text a person wrote.
public class RedactNameTextTests
{
    private const string Utf8Font = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>";
    private static readonly PdfRect Over = new(90, 90, 300, 120);

    private static PdfDocument ArialPage() =>
        ContentTestPdf.Page("BT /F1 12 Tf 100 100 Td (Arial) Tj /F2 12 Tf 0 -50 Td (other) Tj ET", "/Font <</F1 5 0 R /F2 6 0 R>>", RedactionKit.Helvetica, "<</Type /Font /Subtype /Type1 /BaseFont /Arial,Bold>>");

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void FontNameWithACommaIsNotTextToRedact(bool change)
    {
        using var document = ArialPage();
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "Arial"), new RedactionOptions { ChangeMetadata = change });
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        Assert.True(RedactionKit.Holds(result.Bytes, "Arial,Bold"));
    }

    private static PdfDocument Named()
    {
        var document = ContentTestPdf.Page("BT /F1 12 Tf 100 100 Td (Müller Schmidt) Tj ET", "/Font <</F1 5 0 R>>", Utf8Font);
        document.Catalog["Keep"] = new PdfName("MÃ¼ller Schmidt");
        return document;
    }

    [Fact]
    public void NameHoldingTheWordInUtf8IsReported()
    {
        using var document = Named();
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Over)]);
        Assert.False(result.Verification.IsClean);
    }

    [Fact]
    public void NameHoldingTheWordInUtf8IsReplacedWhenMetadataMayChange()
    {
        using var document = Named();
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Over)], new RedactionOptions { ChangeMetadata = true });
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        Assert.DoesNotContain("Schmidt", RedactionKit.Everything(result.Bytes));
    }
}
