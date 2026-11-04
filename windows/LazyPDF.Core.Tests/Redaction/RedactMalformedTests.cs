using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactMalformedTests
{
    private static readonly PdfRect Box = new(90, 690, 300, 720);

    [Fact]
    public void MarksThatMakeNoSenseAreIgnored()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (kept) Tj ET");
        var nan = new TextQuad(double.NaN, 0, 1, 0, 1, 1, 0, 1);
        var flat = new TextQuad(100, 700, 200, 700, 200, 700, 100, 700);
        var result = new PdfRedactor(document).Apply([
            new RedactionMark(5, [new TextQuad(0, 0, 1, 0, 1, 1, 0, 1)]), new RedactionMark(-1, []), new RedactionMark(0, []), new RedactionMark(0, [nan, flat]),
        ]);
        using var output = RedactionKit.Open(result);
        Assert.Equal("kept", RedactionKit.Text(output));
    }

    [Fact]
    public void NoMarksIsJustARewrite()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (kept) Tj ET");
        var result = new PdfRedactor(document).Apply([]);
        using var output = RedactionKit.Open(result);
        Assert.Equal("kept", RedactionKit.Text(output));
        Assert.Empty(result.Report.Pages);
        Assert.Contains("Nothing", result.Report.ToString());
    }

    [Fact]
    public void ContentThatIsBroken()
    {
        using var document = RedactionKit.Page("q q BT /F1 12 Tf 100 700 Td (secret) Tj Q Q Q ) ] >> 1 2 3 foo (unclosed [ (x");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Box, null, "X")]);
        using var output = RedactionKit.Open(result);
        Assert.Equal("X", RedactionKit.Text(output));
    }

    [Fact]
    public void TextObjectLeftOpenDoesNotSwallowTheCover()
    {
        using var document = RedactionKit.Page("1 0 0 1 10 10 cm BT /F1 12 Tf 90 690 Td (secret) Tj");
        var marks = RedactionKit.MarksOf(document, 0, "secret");
        var result = new PdfRedactor(document).Apply(marks, new RedactionOptions { OverlayText = "X" });
        using var output = RedactionKit.Open(result);
        Assert.Equal("X", RedactionKit.Text(output));
        Assert.Equal(marks[0].Quads[0].Bounds, ContentTestPdf.Run(output).Paths.Single().Path.Bounds);
    }

    [Fact]
    public void PageWithoutContentOrResourcesIsFine()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(10, 10, 100, 100))]);
        using var output = RedactionKit.Open(result);
        Assert.Single(output.Pages);
    }

    [Fact]
    public void ImageThatCannotBeDecodedIsRemovedNotLeft()
    {
        using var document = RedactionKit.Page("q 100 0 0 100 100 100 cm /Im1 Do Q", "/XObject <</Im1 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", "this is not zlib data at all"));
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(100, 100, 150, 150))]);
        using var output = RedactionKit.Open(result);
        Assert.Empty(RedactionKit.Images(output));
        Assert.False(RedactionKit.Holds(result.Bytes, "this is not zlib"));
    }

    [Fact]
    public void ImageWhoseMaskIsItselfAndOneThatLiesAboutItsSizeAreSurvived()
    {
        using var document = RedactionKit.Page("q 100 0 0 100 100 100 cm /Im1 Do Q q 100 0 0 100 300 100 cm /Im2 Do Q", "/XObject <</Im1 6 0 R /Im2 7 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /SMask 6 0 R", "abcd");
            pdf.Stream(7, "/Type /XObject /Subtype /Image /Width 8000 /Height 8000 /ColorSpace /DeviceGray /BitsPerComponent 8", "abcd");
        });
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(0, 0, 500, 300))]);
        using var output = RedactionKit.Open(result);
        Assert.Equal(2, result.Report.Images);
        Assert.False(RedactionKit.Holds(result.Bytes, "abcd"));
    }

    [Fact]
    public void FormThatRunsIntoItselfAndImageWithoutColourSpaceAreSurvived()
    {
        using var document = RedactionKit.Page("/Fm1 Do q 100 0 0 100 100 100 cm /Im1 Do Q BT /F1 12 Tf 100 300 Td (loop) Tj ET", "/XObject <</Fm1 6 0 R /Im1 7 0 R>>", pdf =>
        {
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</XObject <</Fm1 6 0 R>>>>", "/Fm1 Do 0 0 10 10 re f");
            pdf.Stream(7, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /BitsPerComponent 8", "abcd");
        });
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(0, 0, 200, 200))]);
        using var output = RedactionKit.Open(result);
        Assert.Equal("loop", RedactionKit.Text(output));
        Assert.Empty(RedactionKit.Images(output));
    }

    [Fact]
    public void ManyMarksOnOnePageStayFast()
    {
        var content = string.Join(" ", Enumerable.Range(0, 200).Select(i => $"BT /F1 6 Tf {10 + i % 20 * 28} {780 - i / 20 * 20} Td (w{i:D3}x) Tj ET"));
        using var document = RedactionKit.Page(content);
        var marks = Enumerable.Range(0, 100).Select(i => RedactionKit.MarksOf(document, 0, $"w{i * 2:D3}x")[0]).ToList();
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var result = new PdfRedactor(document).Apply(marks);
        Assert.InRange(watch.ElapsedMilliseconds, 0, 20_000);
        using var output = RedactionKit.Open(result);
        Assert.Equal(100, RedactionKit.Glyphs(output).Count / 5);
    }
}
