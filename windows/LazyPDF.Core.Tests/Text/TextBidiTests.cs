using Xunit;
using static LazyPDF.Core.Tests.TextTestPdf;

namespace LazyPDF.Core.Tests;

public class TextBidiTests
{
    private static readonly (int, string)[] Hebrew =
    [
        (1, "\u05D0"), (2, "\u05D1"), (3, "\u05D2"), (4, "\u05D3"), (5, "\u05D4"), (6, "\u05D5"),
        (7, "\uFEDF"), (8, "\uFE8E"),
    ];

    [Fact]
    public void AHebrewWordShownRightToLeftReadsInLogicalOrder()
    {
        var page = Text(Line(100, 700, @"\003\002\001"), "", Hebrew);
        Assert.Equal("\u05D0\u05D1\u05D2", page.Text);
        Assert.All(page.Chars, c => Assert.True(c.IsRtl));
        Assert.True(page.Lines[0].IsRtl);
    }

    [Fact]
    public void ALatinSentenceWithAHebrewWordKeepsItsDirection()
    {
        var page = Text(Line(100, 700, @"abc \003\002\001 def"), "", Hebrew);
        Assert.Equal("abc \u05D0\u05D1\u05D2 def", page.Text);
        Assert.False(page.Lines[0].IsRtl);
    }

    [Fact]
    public void ARightToLeftSentenceReadsFromTheRight()
    {
        var page = Text(Line(100, 700, @"abc \006\005\004 \003\002\001"), "", Hebrew);
        Assert.Equal("\u05D0\u05D1\u05D2 \u05D3\u05D4\u05D5 abc", page.Text);
        Assert.True(page.Lines[0].IsRtl);
    }

    [Fact]
    public void NumbersInRightToLeftTextKeepTheirDigitOrder()
    {
        var page = Text(Line(100, 700, @"12.5 \003\002\001"), "", Hebrew);
        Assert.Equal("\u05D0\u05D1\u05D2 12.5", page.Text);
    }

    [Fact]
    public void BracketsAreMirroredBackInRightToLeftRuns()
    {
        var page = Text(Line(100, 700, @"\(\003\002\001\)"), "", Hebrew);
        Assert.Equal("(\u05D0\u05D1\u05D2)", page.Text);
    }

    [Fact]
    public void ArabicPresentationFormsAreFoldedToLetters()
    {
        var page = Text(Line(100, 700, @"\010\007"), "", Hebrew);
        Assert.Equal("\u0644\u0627", page.Text);
    }

    [Fact]
    public void RightToLeftColumnsAreReadRightFirst()
    {
        string right = string.Concat(Enumerable.Range(0, 4).Select(i => Line(330, 700 - i * 12, @"\001\002\003 \001\002\003 \001\002\003 \001\002\003 \001\002\003")));
        string left = string.Concat(Enumerable.Range(0, 4).Select(i => Line(50, 700 - i * 12, @"\004\005\006 \004\005\006 \004\005\006 \004\005\006 \004\005\006")));
        var page = Text(left + right, "", Hebrew);
        Assert.True(page.Lines[0].Bounds.Left > 300);
        Assert.True(page.Lines[4].Bounds.Left < 100);
    }

    [Fact]
    public void ACaretInRightToLeftTextMovesLeftwardsWithTheIndex()
    {
        var page = Text(Line(100, 700, @"\003\002\001"), "", Hebrew);
        // Logical first character is the rightmost glyph, drawn from 110 to 115.
        Assert.Equal(115, page.Chars[0].Quad.X1, 6);
        Assert.Equal(0, page.CaretAt(114, 702));
        Assert.Equal(1, page.CaretAt(111, 702));
        Assert.Equal(3, page.CaretAt(99, 702));
    }
}
