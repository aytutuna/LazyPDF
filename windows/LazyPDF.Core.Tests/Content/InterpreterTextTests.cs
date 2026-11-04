using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class InterpreterTextTests
{
    private static Recorder Run(string content, string resources = "/Font <</F1 5 0 R>>", params string[] objects)
    {
        var all = new[] { ContentTestPdf.Helvetica }.Concat(objects).ToArray();
        return ContentTestPdf.Run(ContentTestPdf.Page(content, resources, all));
    }

    [Fact]
    public void GlyphsAdvanceByTheirWidths()
    {
        var r = Run("BT /F1 10 Tf 100 200 Td (AB) Tj ET");
        Assert.Equal("AB", r.Text);
        Assert.Equal(100, r.Glyphs[0].Matrix.E, 6);
        Assert.Equal(200, r.Glyphs[0].Matrix.F, 6);
        Assert.Equal(10, r.Glyphs[0].Matrix.A, 6);
        Assert.Equal(106.67, r.Glyphs[1].Matrix.E, 2);
        Assert.Equal(6.67, r.Glyphs[0].Advance, 2);
        Assert.Equal(667, r.Glyphs[0].Character.Width);
    }

    [Fact]
    public void BoundsCoverAdvanceByAscentAndDescent()
    {
        var b = Run("BT /F1 10 Tf 100 200 Td (A) Tj ET").Glyphs[0].Bounds;
        Assert.Equal(100, b.Left, 6);
        Assert.Equal(106.67, b.Right, 2);
        Assert.True(b.Bottom < 200 && b.Top > 200);
    }

    [Fact]
    public void TheCtmScalesTheGlyph()
    {
        var g = Run("q 2 0 0 3 10 20 cm BT /F1 10 Tf (A) Tj ET Q").Glyphs[0];
        Assert.Equal(20, g.Matrix.A, 6);
        Assert.Equal(30, g.Matrix.D, 6);
        Assert.Equal(10, g.Matrix.E, 6);
        Assert.Equal(20, g.Matrix.F, 6);
    }

    [Fact]
    public void TjAdjustmentsMoveByThousandths()
    {
        var r = Run("BT /F1 10 Tf 100 0 Td [(A) -1000 (B) 500 (C)] TJ ET");
        Assert.Equal(100 + 6.67 + 10, r.Glyphs[1].Matrix.E, 2);
        Assert.Equal(100 + 6.67 + 10 + 6.67 - 5, r.Glyphs[2].Matrix.E, 2);
        Assert.Equal([0, 2, 4], r.Glyphs.Select(g => g.Element));
    }

    [Fact]
    public void SpacingAndScaleApply()
    {
        // Space is 278; Tc 1 on each character, Tw 5 on the space, Tz 50 halves the lot.
        var r = Run("BT /F1 10 Tf 1 Tc 5 Tw 50 Tz 0 0 Td (A B) Tj ET");
        Assert.Equal((6.67 + 1) * 0.5, r.Glyphs[0].Advance, 2);
        Assert.Equal((2.78 + 1 + 5) * 0.5, r.Glyphs[1].Advance, 2);
        Assert.Equal(0.5 * 10, r.Glyphs[0].Matrix.A, 6);
    }

    [Fact]
    public void LeadingAndQuoteOperators()
    {
        var r = Run("BT /F1 10 Tf 14 TL 100 500 Td (A) Tj T* (B) Tj (C) ' 2 3 (D) \" ET");
        Assert.Equal(486, r.Glyphs[1].Matrix.F, 6);
        Assert.Equal(472, r.Glyphs[2].Matrix.F, 6);
        Assert.Equal(458, r.Glyphs[3].Matrix.F, 6);
        Assert.Equal(1, r.Glyphs[3].Element);
    }

    [Fact]
    public void TdCapitalSetsTheLeading()
    {
        var r = Run("BT /F1 10 Tf 0 -20 TD (A) Tj T* (B) Tj ET");
        Assert.Equal(-40, r.Glyphs[1].Matrix.F, 6);
    }

    [Fact]
    public void TmReplacesTheMatrixAndRiseMovesUp()
    {
        var g = Run("BT /F1 10 Tf 0 1 -1 0 50 60 Tm 4 Ts (A) Tj ET").Glyphs[0];
        Assert.Equal(50 - 4 * 1, g.Matrix.E, 6);
        Assert.Equal(60, g.Matrix.F, 6);
        Assert.Equal(10, g.Matrix.B, 6);
    }

    [Fact]
    public void TheOperatorAndByteOffsetLocateTheCode()
    {
        var r = Run("BT /F1 10 Tf [(AB) 10 (CD)] TJ ET");
        Assert.Equal([0, 1, 0, 1], r.Glyphs.Select(g => g.Offset));
        Assert.Equal([2, 2, 2, 2], r.Where.Select(w => w.Index));
        Assert.Equal([0, 0, 2, 2], r.Glyphs.Select(g => g.Element));
    }

    [Fact]
    public void AMissingFontStillShowsText()
    {
        var r = Run("BT /Nope 10 Tf (AB) Tj ET");
        Assert.Equal("AB", r.Text);
        Assert.Equal(667, r.Glyphs[0].Character.Width);
    }

    [Fact]
    public void TextBeforeAnyFontUsesTheFallback()
    {
        Assert.Equal("A", Run("BT (A) Tj ET").Text);
    }

    [Fact]
    public void RenderModeAndFontSizeAreInTheState()
    {
        var r = Run("BT /F1 12 Tf 3 Tr (A) Tj ET");
        Assert.Equal(3, r.RenderModes[0]);
        Assert.Equal(12, r.Glyphs[0].Matrix.A, 6);
    }

    [Fact]
    public void AnExtGStateSetsTheFont()
    {
        var r = Run("/G1 gs BT (A) Tj ET", "/Font <</F1 5 0 R>> /ExtGState <</G1 <</Font [5 0 R 20]>>>>");
        Assert.Equal(20, r.Glyphs[0].Matrix.A, 6);
    }

    [Fact]
    public void Type3WidthsFollowTheFontMatrix()
    {
        string type3 = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.002 0 0 0.002 0 0] /FirstChar 65 /LastChar 65 /Widths [500] " +
                       "/Encoding <</Type /Encoding /Differences [65 /A]>> /CharProcs <<>>>>";
        var r = Run("BT /T3 10 Tf (AA) Tj ET", "/Font <</T3 6 0 R>>", type3);
        Assert.Equal(1000, r.Glyphs[0].Character.Width, 6);
        Assert.Equal(10, r.Glyphs[0].Advance, 6);
        Assert.Equal("A", r.Glyphs[0].Unicode);
    }

    [Fact]
    public void VerticalFontsAdvanceDownwards()
    {
        string cid = "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 1000>>";
        string type0 = "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-V /DescendantFonts [7 0 R]>>";
        var r = Run("BT /V 10 Tf 100 500 Td <00010002> Tj ET", "/Font <</V 6 0 R>>", type0, cid);
        Assert.Equal(2, r.Glyphs.Count);
        Assert.Equal(-10, r.Glyphs[0].Advance, 6);
        // The origin sits half a width left of and 880 above the text position.
        Assert.Equal(100 - 5, r.Glyphs[0].Matrix.E, 6);
        Assert.Equal(500 - 8.8, r.Glyphs[0].Matrix.F, 6);
        Assert.Equal(490 - 8.8, r.Glyphs[1].Matrix.F, 6);
    }
}
