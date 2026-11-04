using System.Diagnostics;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OcrTextTests
{
    private static OcrWord W(string text, double x, double y, double w = 40, double h = 10) => OcrKit.Word(text, x, y, w, h);

    [Fact]
    public void WordsOfARowJoinLeftToRightWhateverTheirOrder()
    {
        var lines = OcrText.Lines([W("world", 60, 100), W("Hello", 10, 100)]);
        var line = Assert.Single(lines);
        Assert.Equal("Hello world", line.Text);
        Assert.Equal(["Hello", "world"], line.Words.Select(w => w.Text));
        Assert.Equal(new OcrBox(10, 100, 90, 10), line.Box);
    }

    [Fact]
    public void FarApartCellsOfARowAreSeparatedByATab()
    {
        var lines = OcrText.Lines([W("Soup", 10, 100), W("4.50", 300, 100)]);
        Assert.Equal("Soup\t4.50", Assert.Single(lines).Text);
    }

    [Fact]
    public void LinesAreReadTopToBottomAndColumnsOneAfterTheOther()
    {
        var words = new List<OcrWord>();
        for (int row = 0; row < 4; row++)
        {
            words.Add(W($"L{row}a", 10, 100 + row * 14));
            words.Add(W($"L{row}b", 55, 100 + row * 14));
            words.Add(W($"R{row}a", 300, 107 + row * 14));
            words.Add(W($"R{row}b", 345, 107 + row * 14));
        }
        words.Reverse();
        var lines = OcrText.Lines(words);
        Assert.Equal(["L0a L0b", "L1a L1b", "L2a L2b", "L3a L3b", "R0a R0b", "R1a R1b", "R2a R2b", "R3a R3b"], lines.Select(l => l.Text));
    }

    [Fact]
    public void ColumnsThatShareTheirRowsAreATableReadRowByRow()
    {
        var words = new List<OcrWord>();
        for (int row = 0; row < 3; row++)
        {
            words.Add(W($"dish{row}", 10, 100 + row * 14));
            words.Add(W($"{row}.50", 300, 100 + row * 14));
        }
        Assert.Equal(["dish0\t0.50", "dish1\t1.50", "dish2\t2.50"], OcrText.Lines(words).Select(l => l.Text));
    }

    [Fact]
    public void ParagraphsSplitAtGapsAndJoinWrappedLines()
    {
        var page = OcrPage.Of(
        [
            W("Alpha", 10, 10, 280), W("beta", 10, 22, 280), W("gamma-", 10, 34, 280), W("delta", 10, 46, 200),
            W("Second", 10, 90, 280), W("paragraph", 10, 102, 100),
        ], 300, 200);
        var paragraphs = OcrText.Paragraphs(page);
        Assert.Equal(2, paragraphs.Count);
        Assert.Equal("Alpha beta gammadelta", paragraphs[0].Text);
        Assert.Equal("Second paragraph", paragraphs[1].Text);
        Assert.Equal("Alpha\nbeta\ngamma-\ndelta\n\nSecond\nparagraph", OcrText.PageText(page));
    }

    [Fact]
    public void PlainTextSeparatesPagesAndIsEmptyWithoutWords()
    {
        var one = OcrPage.Of([W("One", 10, 10)], 100, 100);
        var empty = OcrPage.Of([], 100, 100);
        Assert.Equal("One\n\n\n\n", OcrText.PlainText([one, empty]));
        Assert.Equal("", OcrText.PlainText([empty, empty]));
    }

    [Fact]
    public void EmptyAndFlatWordsAreDropped()
    {
        var lines = OcrText.Lines([W("", 10, 10), W("  ", 10, 30), W("flat", 10, 50, 40, 0), W("neg", 10, 70, -5, 10), W("ok", 10, 90)]);
        Assert.Equal(["ok"], lines.Select(l => l.Text));
    }

    [Fact]
    public void ControlCharactersBecomeSpaces()
    {
        Assert.Equal("a b\t c", OcrText.CleanLine("  a\u0000\u0001b\t c" + char.ConvertFromUtf32(0x2028) + " "));
    }

    [Fact]
    public void ManyWordsAreOrderedInReasonableTime()
    {
        var words = new List<OcrWord>();
        var random = new Random(7);
        for (int i = 0; i < 4000; i++) words.Add(W("w" + i, random.Next(0, 600), random.Next(0, 800)));
        var clock = Stopwatch.StartNew();
        var lines = OcrText.Lines(words);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(20), clock.Elapsed.ToString());
        Assert.Equal(4000, lines.Sum(l => l.Words.Count));
    }

    [Fact]
    public void StaircaseOfWordsStopsAtTheDepthLimit()
    {
        var words = Enumerable.Range(0, 600).Select(i => W("s" + i, i * 100, i * 30)).ToList();
        var lines = OcrText.Lines(words);
        Assert.Equal(600, lines.Sum(l => l.Words.Count));
    }
}
