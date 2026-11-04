using Xunit;
using static LazyPDF.Core.Tests.TextTestPdf;

namespace LazyPDF.Core.Tests;

public class TextPageTests
{
    [Fact]
    public void GlyphsBecomeCharactersWithBoxes()
    {
        var page = Text("0 0 1 rg " + Line(100, 700, "Hi"));
        Assert.Equal("Hi", page.Text);
        Assert.Equal(2, page.Chars.Count);
        var c = page.Chars[1];
        Assert.Equal("i", c.Text);
        Assert.Equal(10, c.Size, 6);
        Assert.Equal(105, c.Quad.X0, 6);
        Assert.Equal(110, c.Quad.X1, 6);
        Assert.True(c.Quad.Y0 < 700 && c.Quad.Y3 > 700);
        Assert.Equal(new RgbColor(0, 0, 255), c.Color);
        Assert.Equal("Helvetica", c.Font!.Name);
    }

    [Fact]
    public void SpaceGlyphsAndGapsMakeWords()
    {
        var page = Text("BT /F1 10 Tf 100 700 Td [(ab) -600 (cd)] TJ ( ef) Tj ET");
        Assert.Equal(["ab", "cd", "ef"], page.Words.Select(w => w.Text));
        Assert.Contains(page.Chars, c => c.IsImplied && c.Text == " ");
        Assert.Contains(page.Chars, c => c.IsSpace && !c.IsImplied);
        Assert.Equal("ab cd ef", page.Text);
    }

    [Fact]
    public void ATightKernDoesNotSplitAWord()
    {
        var page = Text("BT /F1 10 Tf 100 700 Td [(A) 60 (V) -50 (A)] TJ ET");
        Assert.Single(page.Words);
    }

    [Fact]
    public void LigatureIsOneGlyphWithSeveralCharacters()
    {
        var page = Text(Line(100, 700, @"\001nd"), "", (1, "fi"));
        Assert.Equal("find", page.Text);
        Assert.Equal(3, page.Chars.Count);
        Assert.Equal("fi", page.Chars[0].Text);
        Assert.Equal(5, page.Chars[0].Quad.X1 - page.Chars[0].Quad.X0, 6);
    }

    [Fact]
    public void PresentationFormsBecomePlainLetters()
    {
        var page = Text(Line(100, 700, @"\001\002"), "", (1, "\uFB01"), (2, "\uFEED"));
        Assert.Equal("fi\u0648", page.Text);
    }

    [Fact]
    public void InvisibleOcrTextIsIncludedAndClipOnlyTextIsNot()
    {
        var page = Text("BT /F1 10 Tf 3 Tr 100 700 Td (ocr) Tj 7 Tr (gone) Tj ET");
        Assert.Equal("ocr", page.Text);
        Assert.All(page.Chars, c => Assert.Equal(3, c.RenderMode));
    }

    [Fact]
    public void ClippedAwayAndOffPageTextIsLeftOut()
    {
        string content = "q 0 0 50 50 re W n " + Line(200, 700, "clipped") + "Q " + Line(-300, 700, "off") + Line(100, 100, "kept");
        Assert.Equal("kept", Text(content).Text);
    }

    [Fact]
    public void TextPartlyInsideTheClipStays()
    {
        string content = "q 100 690 22 30 re W n " + Line(100, 700, "abcdefgh") + "Q";
        Assert.Equal("abcde", Text(content).Text);
    }

    [Fact]
    public void ArtifactsCanBeLeftOut()
    {
        string content = Line(100, 700, "body") + "/Artifact BMC " + Line(100, 50, "footer") + "EMC";
        var document = Page(content);
        var all = TextPage.Create(document, document.Pages[0]);
        Assert.Equal("body\n\nfooter", all.Text);
        Assert.Equal([false, true], all.Lines.Select(l => all.Chars[l.Range.Start].IsArtifact));
        var page = TextPage.Create(document, document.Pages[0], new TextPageOptions(IncludeArtifacts: false));
        Assert.Equal("body", page.Text);
    }

    [Fact]
    public void ActualTextReplacesTheGlyphs()
    {
        string content = "/Span <</ActualText (Hello)>> BDC " + Line(100, 700, "xyz") + "EMC " + Line(100, 650, "after");
        var page = Text(content);
        Assert.Equal("Hello\n\nafter", page.Text);
        var first = page.Chars[0];
        Assert.Equal("Hello", first.Text);
        Assert.Equal(100, first.Quad.X0, 6);
        Assert.Equal(115, first.Quad.X1, 6);
    }

    [Fact]
    public void ActualTextInUtf16IsRead()
    {
        string content = "/Span <</ActualText <FEFF00E900E8>>> BDC " + Line(100, 700, "ab") + "EMC";
        Assert.Equal("\u00E9\u00E8", Text(content).Text);
    }

    [Fact]
    public void EmptyActualTextHidesTheGlyphs()
    {
        string content = "/Span <</ActualText ()>> BDC " + Line(100, 700, "xyz") + "EMC " + Line(100, 650, "kept");
        Assert.Equal("kept", Text(content).Text);
    }

    [Fact]
    public void GlyphDrawnTwiceForBoldIsKeptOnce()
    {
        string content = Line(100, 700, "Bold") + Line(100.4, 700, "Bold");
        Assert.Equal("Bold", Text(content).Text);
        var document = Page(content);
        var raw = TextPage.Create(document, document.Pages[0], new TextPageOptions(RemoveDuplicates: false));
        Assert.Equal(8, raw.Chars.Count);
    }

    [Fact]
    public void RepeatedLettersNextToEachOtherSurvive()
    {
        Assert.Equal("ll", Text(Line(100, 700, "ll")).Text);
    }

    [Fact]
    public void GlyphsWithoutTextKeepTheirBoxes()
    {
        var page = Text(Line(100, 700, @"a\001b"), "", (1, ""));
        Assert.Equal(3, page.Chars.Count);
        Assert.Equal("ab", page.Text);
        Assert.Single(page.Words);
    }

    [Fact]
    public void FormTextKnowsItsFormAndOperator()
    {
        var document = Page("/Fm Do " + Line(100, 600, "page"), "/Font <</F1 5 0 R>> /XObject <</Fm 7 0 R>>", "", pdf =>
        {
            Font(pdf, 5);
            pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", Line(100, 700, "form"));
        });
        var page = TextPage.Create(document, document.Pages[0]);
        var inForm = page.Chars.First(c => c.Text == "f");
        var onPage = page.Chars.First(c => c.Text == "p");
        Assert.NotNull(inForm.Form);
        Assert.Null(onPage.Form);
        Assert.Equal(4, onPage.OperatorIndex);
        Assert.Equal(3, inForm.OperatorIndex);
    }

    [Fact]
    public void OperatorElementAndOffsetLocateTheGlyph()
    {
        var page = Text("BT /F1 10 Tf 100 700 Td [(ab) 5 (cd)] TJ ET");
        var d = page.Chars.First(c => c.Text == "d");
        Assert.Equal(2, d.Element);
        Assert.Equal(1, d.Offset);
        Assert.Equal(page.Chars[0].OperatorIndex, d.OperatorIndex);
    }

    [Fact]
    public void RotatedTextKeepsItsSlantInUserSpace()
    {
        var page = Text("BT /F1 10 Tf 0 1 -1 0 300 300 Tm (up) Tj ET");
        var q = page.Chars[0].Quad;
        Assert.Equal(q.Y0, q.Y3, 6);
        Assert.True(q.Y1 > q.Y0);
        Assert.Equal("up", page.Text);
    }

    [Fact]
    public void EmptyAndBrokenContentGiveAnEmptyPage()
    {
        Assert.Empty(Text("").Chars);
        Assert.Equal("", Text("(((( << [ BT ET Tj").Text);
    }

    [Fact]
    public void ZeroSizeTextIsIgnored()
    {
        Assert.Equal("", Text("BT /F1 0 Tf 100 700 Td (x) Tj ET").Text);
    }
}
