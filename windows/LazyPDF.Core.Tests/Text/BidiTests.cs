using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class BidiTests
{
    // Tests/Fixtures/golden/bidi/bidi-character.txt, lines of the Unicode conformance file; the Swift suite reads the same file.
    [Fact]
    public void CuratedConformanceLinesPass() => Assert.True(CheckLines("bidi-character.txt") >= 250);

    // Depth overflow (X5a to X7) and L1 with a paragraph separator and a tab, which the conformance file does not reach.
    [Fact]
    public void OverflowAndLineEndLinesPass() => Assert.Equal(5, CheckLines("bidi-overflow.txt"));

    private static int CheckLines(string file)
    {
        int checkedLines = 0;
        foreach (string line in Golden.Input("bidi", file).Split('\n'))
        {
            if (line.Length == 0 || line[0] == '#') continue;
            string[] f = line.Split(';');
            int[] cps = [.. f[0].Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(s => Convert.ToInt32(s, 16))];
            var text = new StringBuilder();
            var firstUnit = new List<int>();
            foreach (int cp in cps)
            {
                firstUnit.Add(text.Length);
                text.Append(char.ConvertFromUtf32(cp));
            }
            int direction = int.Parse(f[1]);
            var para = new BidiParagraph(text.ToString(), direction == 2 ? BidiParagraph.Auto : direction);
            Assert.True(int.Parse(f[2]) == para.Level, line);

            var levels = para.LineLevels(0, text.Length);
            string actualLevels = string.Join(' ', firstUnit.Select(u => levels[u] < 0 ? "x" : levels[u].ToString()));
            Assert.True(f[3] == actualLevels, $"{line}\nlevels {actualLevels}");

            var unitToIndex = new Dictionary<int, int>();
            for (int i = 0; i < firstUnit.Count; i++) unitToIndex[firstUnit[i]] = i;
            string order = string.Join(' ', para.VisualOrder(0, text.Length).Where(unitToIndex.ContainsKey).Select(u => unitToIndex[u]));
            Assert.True(f[4] == order, $"{line}\norder {order}");
            checkedLines++;
        }
        return checkedLines;
    }

    private static string Visual(string text, int baseLevel = BidiParagraph.Auto)
    {
        var para = new BidiParagraph(text, baseLevel);
        var sb = new StringBuilder();
        foreach (int u in para.VisualOrder(0, text.Length)) sb.Append(text[u]);
        return sb.ToString();
    }

    [Fact]
    public void AHebrewWordIsReversedAndNumbersKeepTheirOrder()
    {
        Assert.Equal("\u05D2\u05D1\u05D0", Visual("\u05D0\u05D1\u05D2"));
        Assert.Equal("12 \u05D1\u05D0", Visual("\u05D0\u05D1 12"));
    }

    [Fact]
    public void TheParagraphLevelComesFromTheFirstStrongCharacter()
    {
        Assert.Equal(1, new BidiParagraph("123 \u0627").Level);
        Assert.Equal(0, new BidiParagraph("abc \u0627").Level);
        Assert.Equal(0, new BidiParagraph("123").Level);
        Assert.Equal(1, new BidiParagraph("abc", 1).Level);
        Assert.Equal(0, new BidiParagraph("\u2067\u05D0\u2069a").Level);
    }

    [Fact]
    public void TrailingSpacesTakeTheParagraphLevelOnTheLine()
    {
        var para = new BidiParagraph("\u202Eab  ", 0);
        Assert.Equal([-1, 1, 1, 1, 1], para.Levels.Select(l => (int)l));
        Assert.Equal([-1, 1, 1, 0, 0], para.LineLevels(0, 5).Select(l => (int)l));
        Assert.Equal([2, 1, 3, 4], para.VisualOrder(0, 5));
    }

    [Fact]
    public void ALineCutInTheMiddleResolvesItsOwnTrailingSpace()
    {
        var para = new BidiParagraph("\u05D0 \u05D1", 0);
        Assert.Equal([1, 0], para.LineLevels(0, 2).Select(l => (int)l));
    }

    [Fact]
    public void ASurrogatePairIsOneCharacterAndStaysInOrder()
    {
        // U+10800 CYPRIOT SYLLABLE A is right to left.
        string text = "a \uD802\uDC00\uD802\uDC01";
        var para = new BidiParagraph(text);
        Assert.Equal([0, 0, 1, 1, 1, 1], para.Levels.Select(l => (int)l));
        Assert.Equal([0, 1, 4, 5, 2, 3], para.VisualOrder(0, text.Length));
    }

    [Fact]
    public void MirroringAndPairedBracketsComeFromTheTables()
    {
        Assert.Equal(')', BidiData.Mirror('('));
        Assert.Equal('<', BidiData.Mirror('>'));
        Assert.Equal('a', BidiData.Mirror('a'));
        Assert.Equal(')', BidiData.PairedBracket('(', out bool opening));
        Assert.True(opening);
        Assert.Equal('[', BidiData.PairedBracket(']', out opening));
        Assert.False(opening);
        Assert.Equal(0, BidiData.PairedBracket('a', out _));
        Assert.Equal(BidiType.AL, BidiData.TypeOf(0x0627));
        Assert.Equal(BidiType.R, BidiData.TypeOf(0x05D0));
        Assert.Equal(BidiType.AN, BidiData.TypeOf(0x0661));
        Assert.Equal(BidiType.AL, BidiData.TypeOf(0x08A0));
        Assert.Equal(BidiType.L, BidiData.TypeOf(0x110000));
    }

    [Fact]
    public void ABracketPairInsideAnRtlRunTakesItsDirection()
    {
        // Hebrew (a) Hebrew: the parentheses close around Latin text but sit in a right to left context.
        Assert.Equal("\u05D1 (a) \u05D0".Length, Visual("\u05D0 (a) \u05D1").Length);
        var para = new BidiParagraph("\u05D0(b)\u05D1", 1);
        Assert.Equal([1, 1, 2, 1, 1], para.Levels.Select(l => (int)l));
    }

    [Fact]
    public void AMissingOrExtraFormattingCharacterIsHarmless()
    {
        var para = new BidiParagraph("a\u202C\u2069b\u202B", 0);
        Assert.Equal([0, -1, 0, 0, -1], para.Levels.Select(l => (int)l));
    }

    [Fact]
    public void DeeplyNestedEmbeddingsAndIsolatesStopAtTheLimit()
    {
        string deep = string.Concat(Enumerable.Repeat("\u202B\u2066", 200)) + "a";
        var para = new BidiParagraph(deep, 0);
        Assert.InRange(para.Levels.Max(), 0, 126);
        string brackets = string.Concat(Enumerable.Repeat("(", 5000)) + "\u05D0" + string.Concat(Enumerable.Repeat(")", 5000));
        Assert.Equal(brackets.Length, new BidiParagraph(brackets, 0).VisualOrder(0, brackets.Length).Length);
    }

    [Fact]
    public void ALongParagraphResolvesQuickly()
    {
        string text = string.Concat(Enumerable.Repeat("abc \u05D0\u05D1\u05D2 123 (x) ", 20000));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var para = new BidiParagraph(text, 0);
        para.VisualOrder(0, text.Length);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10));
    }
}
