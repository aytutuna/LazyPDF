using Xunit;
using static LazyPDF.Core.Tests.TextTestPdf;

namespace LazyPDF.Core.Tests;

public class TextReviewTests
{
    [Fact(Timeout = 20000)]
    public async Task NotANumberGlyphEdgeDoesNotHangTheColumnScan()
    {
        string content = Line(100, 700, "left") + Line(300, 700, "right")
            + $"BT /F1 10 Tf 1 0 0 {Big(306)} 100 100 Tm (x) Tj ET\n";
        var page = await Task.Run(() => Text(content, "/UserUnit 1000"));
        Assert.Contains("left", page.Text);
    }

    [Fact(Timeout = 20000)]
    public async Task GlyphsWhoseEmOverflowDoNotHangTheLineJoin()
    {
        string bbox = "318" + new string('0', 155);
        string far = Big(300);
        string content = $"BT /F1 1 Tf 1 -1 {Big(150)} {Big(150)} {far} {far} Tm (a) Tj ET\n"
            + "BT /F2 10 Tf 1 -1 1 1 100 700 Tm (b) Tj ET\n"
            + $"BT /F1 1 Tf 1 -1 {Big(150)} {Big(150)} -{far} -{far} Tm (c) Tj ET\n";
        var document = Page(content, "/Font <</F1 5 0 R /F2 7 0 R>>", "/UserUnit 2", pdf =>
        {
            Font(pdf, 7);
            pdf.Obj(5, $"<</Type /Font /Subtype /Type3 /FontBBox [0 -{bbox} 8 {bbox}] /FontMatrix [1 0 0 1 0 0] /FirstChar 97 /LastChar 99 "
                + "/Widths [6 6 6] /Encoding <</Type /Encoding /Differences [97 /a /b /c]>> /CharProcs <</a 6 0 R /b 6 0 R /c 6 0 R>>>>");
            pdf.Stream(6, "", "6 0 0 -2 6 6 d1 0 0 6 6 re f");
        });
        var page = await Task.Run(() => TextPage.Create(document, document.Pages[0]));
        Assert.Contains("b", page.Text);
        Assert.Null(TextInvariants.Check(page));
    }

    [Fact]
    public void LoneSurrogateInAMapDoesNotBreakThePage()
    {
        var page = Text(Line(100, 700, "A"), "", (65, "\uD800\uFB01"));
        Assert.Single(page.Chars);
    }

    [Fact]
    public void ShearedTextStaysOneLine()
    {
        var page = Text("BT /F1 10 Tf 1 0 0.3 1 100 700 Tm (hello world, in italic) Tj ET");
        Assert.Equal("hello world, in italic", page.Text);
        Assert.Single(page.Lines);
    }

    [Fact]
    public void NarrowRepeatedLettersAreNotDuplicates()
    {
        var page = Text("BT /F1 10 Tf 30 Tz 100 700 Td (Hello million) Tj ET");
        Assert.Equal("Hello million", page.Text);
    }

    [Fact]
    public void ActualTextIsDecodedAsPdfDocEncoding()
    {
        var page = Text(@"/Span <</ActualText (\204)>> BDC BT /F1 10 Tf 100 700 Td (-) Tj ET EMC");
        Assert.Equal("\u2014", page.Text);
    }

    [Fact]
    public void Type3GlyphsKeepTheirOwnSize()
    {
        var page = Page("BT /F1 1 Tf 100 700 Td (ab ab) Tj ET", "/Font <</F1 5 0 R>>", "", pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /Type3 /FontBBox [0 -2 8 6] /FontMatrix [1 0 0 1 0 0] /FirstChar 32 /LastChar 98 "
                + "/Widths [" + string.Join(" ", Enumerable.Range(32, 67).Select(c => c == 32 ? 3 : 6)) + "] "
                + "/Encoding <</Type /Encoding /Differences [32 /space 97 /a /b]>> /CharProcs <</a 6 0 R /b 6 0 R /space 6 0 R>>>>");
            pdf.Stream(6, "", "6 0 0 -2 6 6 d1 0 0 6 6 re f");
        });
        var text = TextPage.Create(page, page.Pages[0]);
        Assert.Single(text.Lines);
        Assert.True(text.Chars[0].Quad.Bounds.Height > 5);
    }

    [Fact]
    public void PercentSignStaysWithItsNumberInRightToLeftText()
    {
        // Visual order: 50% to the left of an Hebrew letter.
        var page = Text(Line(100, 700, @"50%\001"), "", (1, "\u05D0"));
        Assert.EndsWith("50%", page.Text.Replace("\u05D0", "").Trim());
        Assert.Contains("50%", page.Text);
    }

    [Fact]
    public void WholeWordSearchFindsAMatchOverlappingARejectedOne()
    {
        var page = Text(Line(100, 700, "xab ab ab"));
        var hits = TextSearch.Find(page, "ab ab", new TextSearchOptions(WholeWord: true));
        Assert.Single(hits);
        Assert.Equal(4, hits[0].Range.Start);
    }

    [Fact]
    public void RegexPatternIsFoldedWithThePage()
    {
        var page = Text(Line(100, 700, @"\001ehir"), "", (1, "\u015F"));
        var options = new TextSearchOptions(Regex: true, FoldDiacritics: true);
        Assert.Single(TextSearch.Find(page, "\\b\u015Fehir\\b", options));
    }

    [Fact]
    public void DottedCapitalIMatchesPlainI()
    {
        var page = Text(Line(100, 700, @"\001STANBUL"), "", (1, "\u0130"));
        Assert.Single(TextSearch.Find(page, "istanbul"));
    }
}
