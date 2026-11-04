using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactTextTests
{
    private static (RedactionResult Result, List<DrawnGlyph> Before, List<DrawnGlyph> After) Redact(string content, string word = RedactionKit.Marker, string resources = "")
    {
        using var document = RedactionKit.Page(content, resources);
        var before = RedactionKit.Glyphs(document);
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, word));
        using var output = RedactionKit.Open(result);
        return (result, before, RedactionKit.Glyphs(output));
    }

    // The glyphs that stay are where they were: compare by position, in order, without the removed run.
    private static void AssertStay(List<DrawnGlyph> before, List<DrawnGlyph> after, string removed)
    {
        var expected = new List<DrawnGlyph>(before);
        for (int at; (at = RedactionKit.Text(expected).IndexOf(removed, StringComparison.Ordinal)) >= 0;) expected.RemoveRange(at, removed.Length);
        Assert.Equal(expected.Count, after.Count);
        for (int i = 0; i < expected.Count; i++)
        {
            Assert.Equal(expected[i].Text, after[i].Text);
            Assert.Equal(expected[i].X, after[i].X, 0.01);
            Assert.Equal(expected[i].Y, after[i].Y, 0.01);
        }
    }

    [Fact]
    public void ShowStringLosesTheMarkedGlyphsAndTheRestStaysPut()
    {
        var (result, before, after) = Redact("BT /F1 12 Tf 50 700 Td (Hello ZQXMARKER world) Tj ET");
        AssertStay(before, after, RedactionKit.Marker);
        Assert.Equal("Hello  world", RedactionKit.Text(after));
        Assert.False(RedactionKit.Holds(result.Bytes, RedactionKit.Marker));
        Assert.Equal(9, result.Report.Glyphs);
    }

    [Fact]
    public void KerningArrayKeepsItsAdjustmentsAround()
    {
        var (_, before, after) = Redact("BT /F1 12 Tf 50 700 Td [(Hello ) -250 (ZQX) 120 (MARKER) -80 ( world)] TJ ET");
        AssertStay(before, after, RedactionKit.Marker);
    }

    [Fact]
    public void NextLineOperatorsStayInStep()
    {
        var (_, before, after) = Redact("BT /F1 12 Tf 14 TL 50 700 Td (one) Tj (two ZQXMARKER) ' 3 1 (three ZQXMARKER x) \" (four) ' ET");
        Assert.Equal("one" + "two " + "three  x" + "four", RedactionKit.Text(after));
        AssertStay(before, after, RedactionKit.Marker);
        Assert.Equal(before.First(g => g.Text == "f").Y, after.First(g => g.Text == "f").Y, 0.01);
    }

    [Fact]
    public void CharacterAndWordSpacingAndScaleAreAccountedFor()
    {
        var (_, before, after) = Redact("BT /F1 12 Tf 50 700 Td 0.5 Tc 4 Tw 80 Tz (a ZQXMARKER b) Tj (c) Tj ET");
        AssertStay(before, after, RedactionKit.Marker);
        // The string after the removal continues from where the removed text ended.
        Assert.Equal(before.Single(g => g.Text == "c").X, after.Single(g => g.Text == "c").X, 0.01);
    }

    [Fact]
    public void InvisibleTextOfAnOcrLayerGoesToo()
    {
        var (result, _, after) = Redact("BT /F1 12 Tf 3 Tr 50 700 Td (ocr ZQXMARKER layer) Tj ET");
        Assert.Equal("ocr  layer", RedactionKit.Text(after));
        Assert.False(RedactionKit.Holds(result.Bytes, RedactionKit.Marker));
    }

    [Fact]
    public void ClippedTextOutsideTheMarkStays()
    {
        var (_, _, after) = Redact("q 0 0 10 10 re W n BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET Q BT /F1 12 Tf 50 100 Td (visible) Tj ET", "visible");
        Assert.Equal("ZQXMARKER", RedactionKit.Text(after));
    }

    [Fact]
    public void ClippedTextUnderAMarkIsRemoved()
    {
        using var document = RedactionKit.Page("q 0 0 40 800 re W n BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET Q");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(40, 690, 200, 720))]);
        using var output = RedactionKit.Open(result);
        Assert.Equal("", RedactionKit.Text(output));
        Assert.False(RedactionKit.Holds(result.Bytes, RedactionKit.Marker));
    }

    [Fact]
    public void ShowStringsOfSeveralPlacesAreEachCut()
    {
        var (_, before, after) = Redact("BT /F1 12 Tf 50 700 Td (ZQXMARKER top) Tj ET BT /F1 12 Tf 50 650 Td (mid ZQXMARKER) Tj ET");
        Assert.Equal(before.Count - 18, after.Count);
        Assert.Equal(" topmid ", RedactionKit.Text(after));
    }

    [Fact]
    public void MarkOnEmptyAreaRemovesNothing()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 50 700 Td (kept) Tj ET");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(300, 300, 400, 400))]);
        using var output = RedactionKit.Open(result);
        Assert.Equal("kept", RedactionKit.Text(output));
        Assert.Equal(0, result.Report.Glyphs);
        Assert.Contains("Nothing", result.Report.ToString());
    }

    [Fact]
    public void RectangleOverPartOfAGlyphTakesIt()
    {
        using var document = RedactionKit.Page("BT /F1 20 Tf 50 700 Td (ABCDE) Tj ET");
        var glyphs = RedactionKit.Glyphs(document);
        // A box over the middle of C only.
        double x = glyphs[2].X + 3;
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(x, 695, x + 2, 715))]);
        using var output = RedactionKit.Open(result);
        Assert.Equal("ABDE", RedactionKit.Text(output));
    }

    [Fact]
    public void TheDocumentItselfIsNotChanged()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 50 700 Td (Hello ZQXMARKER) Tj ET");
        var original = document.SaveRewrite();
        _ = new PdfRedactor(document).Apply([RedactionKit.MarkOf(document, 0, RedactionKit.Marker)]);
        Assert.Equal("Hello ZQXMARKER", RedactionKit.Text(document));
        Assert.Equal(original.Length, document.SaveRewrite().Length);
    }
}
