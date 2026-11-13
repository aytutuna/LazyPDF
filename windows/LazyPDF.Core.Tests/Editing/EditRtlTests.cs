using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class EditRtlTests
{
    private sealed class ScriptFonts : IFontSource
    {
        public FontFile? Find(string family, FontStyles style) => new(TrueTypeBuilder.BuildScript());
    }

    private static readonly ScriptFonts Fonts = new();

    // A page with the text set by the box writer: a Hebrew line is drawn in display order against the right edge of the box.
    private static PdfEditSession Page(string text, double width = 200)
    {
        var first = PdfEditSession.Open(AnnotationFixtures.Blank(1).SaveRewrite());
        Assert.True(new PageEditor(first, 0, Fonts).AddTextBox(new PdfRect(50, 600, 50 + width, 700), text, new TextBoxStyle("Script Sans", Size: 14)).Done);
        return PdfEditSession.Open(first.Current.ToArray());
    }

    private static TextPage Read(PdfEditSession session)
    {
        var document = PdfDocument.Open(session.Current.ToArray());
        return TextPage.Create(document, document.Pages[0]);
    }

    private static (double Left, double Right) Extent(PdfEditSession session)
    {
        var chars = Read(session).Chars.Where(c => !c.IsSpace).ToList();
        return (chars.Min(c => c.Quad.Bounds.Left), chars.Max(c => c.Quad.Bounds.Right));
    }

    private static void Near(double expected, double actual) => Assert.InRange(actual, expected - 0.5, expected + 0.5);

    private static string Content(PdfEditSession session) => Encoding.Latin1.GetString(PdfDocument.Open(session.Current.ToArray()).Pages[0].Contents());

    [Fact]
    public void ALoneHebrewLineIsReadAsRightAligned()
    {
        var editor = new PageEditor(Page("אבג דהו"), 0, Fonts);
        Assert.Equal(TextAlignment.Right, Assert.Single(editor.Objects.OfType<TextObject>()).Alignment);
    }

    [Fact]
    public void ALatinLineStaysLeftAligned()
    {
        var editor = new PageEditor(Page("abc def"), 0, Fonts);
        Assert.Equal(TextAlignment.Left, Assert.Single(editor.Objects.OfType<TextObject>()).Alignment);
    }

    [Theory]
    [InlineData("אב")]
    [InlineData("אבג דהו זחט יכל")]
    public void ReplacingAWholeHebrewLineKeepsItsRightEdge(string text)
    {
        var session = Page("אבג דהו");
        var (_, right) = Extent(session);
        var editor = new PageEditor(session, 0, Fonts);
        var block = Assert.Single(editor.Objects.OfType<TextObject>());
        Assert.True(editor.ReplaceText(block.Range, text).Done);
        Assert.Equal(text, Read(session).Text.Trim());
        Near(right, Extent(session).Right);
    }

    [Fact]
    public void ReplacingAHebrewLineInTwoColorsKeepsTheWordsInOrder()
    {
        var session = Page("אבג דהו");
        var red = new RgbColor(255, 0, 0);
        var first = new PageEditor(session, 0, Fonts);
        Assert.True(first.SetTextStyle([TextSearch.Find(Read(session), "אבג", new TextSearchOptions(MatchCase: true)).First().Range], new TextStyleChange(Color: red)).Done);
        var editor = new PageEditor(session, 0, Fonts);
        Assert.True(editor.ReplaceText(Assert.Single(editor.Objects.OfType<TextObject>()).Range, "זחט יכל").Done);
        var now = Read(session);
        Assert.Equal("זחט יכל", now.Text.Trim());
        var word = TextSearch.Find(now, "זחט", new TextSearchOptions(MatchCase: true)).First().Range;
        for (int i = word.Start; i < word.End; i++) Assert.Equal(red, now.Chars[i].Color);
    }

    [Fact]
    public void ReplacingAHebrewWordStartsTheNewTextAtTheLeftEdgeOfTheOldOne()
    {
        var session = Page("אבג דהו");
        var document = PdfDocument.Open(session.Current.ToArray());
        var old = TextPage.Create(document, document.Pages[0]);
        var word = TextSearch.Find(old, "אבג", new TextSearchOptions(MatchCase: true)).First().Range;
        double left = Enumerable.Range(word.Start, word.End - word.Start).Min(i => old.Chars[i].Quad.Bounds.Left);
        var editor = new PageEditor(session, 0, Fonts);
        Assert.True(editor.ReplaceText(word, "זח").Done);
        var now = Read(session);
        Assert.Contains("זח", now.Text);
        var moved = TextSearch.Find(now, "זח", new TextSearchOptions(MatchCase: true)).First().Range;
        Near(left, Enumerable.Range(moved.Start, moved.End - moved.Start).Min(i => now.Chars[i].Quad.Bounds.Left));
    }

    [Fact]
    public void ReplacingTheTextOfABlockKeepsItsRightEdgeAndWrapsByDirection()
    {
        var session = Page("אבג דהו");
        var (_, right) = Extent(session);
        var editor = new PageEditor(session, 0, Fonts);
        var block = Assert.Single(editor.Objects.OfType<TextObject>());
        Assert.True(editor.ReplaceParagraph(block, "דהו אבג").Done);
        Assert.Equal("דהו אבג", Read(session).Text.Trim());
        Near(right, Extent(session).Right);
    }

    [Fact]
    public void SelectingEditedHebrewAgainStillFindsItsCharacters()
    {
        var session = Page("אבג דהו");
        var editor = new PageEditor(session, 0, Fonts);
        var block = Assert.Single(editor.Objects.OfType<TextObject>());
        Assert.True(editor.ReplaceText(block.Range, "זחט").Done);
        var again = new PageEditor(session, 0, Fonts);
        Assert.True(again.ReplaceText(Assert.Single(again.Objects.OfType<TextObject>()).Range, "יכל").Done);
        Assert.Equal("יכל", Read(session).Text.Trim());
    }

    [Fact]
    public void MirroredBracketsInEditedHebrewCarryTheirActualText()
    {
        var session = Page("abc");
        var editor = new PageEditor(session, 0, Fonts);
        Assert.True(editor.ReplaceText(Assert.Single(editor.Objects.OfType<TextObject>()).Range, "אב (גד)").Done);
        Assert.Contains("/ActualText", Content(session));
        Assert.Equal("אב (גד)", Read(session).Text.Trim());
    }
}
