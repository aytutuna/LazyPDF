using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactOverlayTests
{
    private static readonly PdfRect Box = new(100, 690, 300, 720);

    private static string Shown(RedactionResult result)
    {
        using var output = RedactionKit.Open(result);
        return RedactionKit.Text(output);
    }

    [Fact]
    public void CoverIsDrawnInTheFillColourAndCarriesTheText()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Box, [1, 0, 0], "(b)(6)")]);
        Assert.Equal("(b)(6)", Shown(result));
        using var output = PdfDocument.Open(result.Bytes);
        var recorder = ContentTestPdf.Run(output);
        var cover = recorder.Paths.Single();
        Assert.Equal(Box, cover.Path.Bounds);
        Assert.Equal([1.0, 0, 0], cover.State.FillColor.Components);
        Assert.Equal("(b)(6)", RedactionKit.Text(output));
    }

    [Fact]
    public void OptionsGiveTheDefaultsAndTextOnDarkIsWhite()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Box)], new RedactionOptions { Fill = [0.1], OverlayText = "REDACTED" });
        using var output = RedactionKit.Open(result);
        var recorder = ContentTestPdf.Run(output);
        Assert.Equal(0.1, recorder.Paths.Single().State.FillColor.Components[0], 6);
        Assert.Equal("REDACTED", RedactionKit.Text(output));
        Assert.Contains("1 g", RedactionKit.Latin(output));
    }

    [Fact]
    public void RepeatedOverlayFillsTheWidth()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(100, 690, 400, 720))], new RedactionOptions { OverlayText = "(b)(6)", RepeatOverlay = true });
        using var output = RedactionKit.Open(result);
        string shown = RedactionKit.Text(output);
        Assert.True(shown.Split("(b)(6)").Length > 3, shown);
        Assert.All(RedactionKit.Glyphs(output), g => Assert.InRange(g.X, 100, 400));
    }

    [Fact]
    public void LongOverlayShrinksToFit()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(100, 690, 180, 720))], new RedactionOptions { OverlayText = "PRIVILEGED AND CONFIDENTIAL" });
        using var output = RedactionKit.Open(result);
        var glyphs = RedactionKit.Glyphs(output);
        Assert.Equal("PRIVILEGED AND CONFIDENTIAL", RedactionKit.Text(glyphs));
        Assert.InRange(glyphs[^1].X, 100, 180);
    }

    [Fact]
    public void TurkishOverlayIsEmbeddedFromTheFontSource()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET");
        var result = new PdfRedactor(document, new ArialSource()).Apply([RedactionMark.FromRect(0, new PdfRect(100, 690, 300, 720))], new RedactionOptions { OverlayText = "GİZLİ ŞİİR" });
        Assert.Equal("GİZLİ ŞİİR", Shown(result));
    }

    [Fact]
    public void NoFontForTheOverlayIsAnErrorAndChangesNothing()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET");
        var redactor = new PdfRedactor(document);
        var error = Assert.Throws<InvalidOperationException>(() => redactor.Apply([RedactionMark.FromRect(0, Box)], new RedactionOptions { OverlayText = "GİZLİ" }));
        Assert.Equal(RedactionText.NoFont, error.Message);
        Assert.Equal("secret words", RedactionKit.Text(document));
    }

    [Fact]
    public void ARotatedQuadIsCoveredAndItsTextTurns()
    {
        using var document = RedactionKit.Page("q 0 1 -1 0 300 100 cm BT /F1 12 Tf 0 0 Td (rotated secret) Tj ET Q");
        var marks = RedactionKit.MarksOf(document, 0, "secret");
        var result = new PdfRedactor(document).Apply(marks.Select(m => m with { OverlayText = "X-1" }).ToList());
        using var output = RedactionKit.Open(result);
        Assert.Equal("rotated X-1", RedactionKit.Text(output));
        var glyphs = RedactionKit.Glyphs(output);
        // The overlay runs up the page like the text it covers.
        Assert.True(glyphs[^1].Y > glyphs[^3].Y);
    }
}
