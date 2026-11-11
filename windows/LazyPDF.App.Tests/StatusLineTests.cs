using System.Globalization;
using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

// The status line shows six words at most; the whole sentence stays the accessible name.
public sealed class StatusLineTests
{
    [Fact]
    public void AShortSentenceIsShownWithoutItsFullStop() =>
        Assert.Equal("Saved a.pdf", StatusLine.Short("Saved a.pdf."));

    [Fact]
    public void ALongOneIsCutAtItsFirstSentence() =>
        Assert.Equal("Sent to Lazy Print", StatusLine.Short("Sent to Lazy Print. It opens in a moment."));

    [Fact]
    public void ALongSentenceIsCutAtAColonOrAComma() =>
        Assert.Equal("Not saved", StatusLine.Short("Not saved: the disk is full and nothing else could be done."));

    [Fact]
    public void WithNoPlaceToCutItKeepsSixWords()
    {
        string text = StatusLine.Short("One two three four five six seven eight");

        Assert.Equal("One two three four five six…", text);
        Assert.Equal(StatusLine.MaxWords, StatusLine.Words(text));
    }

    [Fact]
    public void NothingGivesNothing() => Assert.Equal("", StatusLine.Short("   "));

    [Fact]
    public void WordsCountOnlyTokensWithALetterOrDigit() =>
        Assert.Equal(3, StatusLine.Words("Page 3 · done —"));

    [Fact]
    public void ALabelThatDiffersFromTheNumberShowsBoth() =>
        Assert.Equal("Page iv (4 of 10)", MainWindow.PageReadout("iv", 3, 10));

    [Fact]
    public void APlainLabelShowsTheNumberOnly() =>
        Assert.Equal("Page 4 of 10", MainWindow.PageReadout("4", 3, 10));

    [Fact]
    public void LetterSizeReadsInMillimetresAndInches()
    {
        Assert.Equal("216 × 279 mm", MainWindow.SizeReadout(612, 792, true));
        Assert.Equal("8.5 × 11 in", MainWindow.SizeReadout(612, 792, false));
    }

    [Fact]
    public void InchesUseTheDecimalCommaOfTheCulture()
    {
        var saved = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("tr-TR");
        try { Assert.Contains("8,5", MainWindow.SizeReadout(612, 792, false)); }
        finally { CultureInfo.CurrentCulture = saved; }
    }
}
