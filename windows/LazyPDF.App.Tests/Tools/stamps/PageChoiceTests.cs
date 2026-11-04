using LazyPDF.App.Tools.Stamps;
using Xunit;

namespace LazyPDF.App.Tests;

// Which pages a stamp goes on, as the form states it.
public sealed class PageChoiceTests
{
    [Fact]
    public void EveryPageIsNoListAtAll()
    {
        Assert.Equal((null, null), PageChoice.Resolve(PageSet.All, "", 5));
    }

    [Fact]
    public void OddAndEvenCountFromTheFirstPageAsOne()
    {
        Assert.Equal([0, 2, 4], PageChoice.Resolve(PageSet.Odd, "", 5).Pages);
        Assert.Equal([1, 3], PageChoice.Resolve(PageSet.Even, "", 5).Pages);
    }

    [Fact]
    public void TypedPagesComeBackZeroBased()
    {
        var (pages, error) = PageChoice.Resolve(PageSet.Typed, "1-3, 5", 6);

        Assert.Null(error);
        Assert.Equal([0, 1, 2, 4], pages);
    }

    [Fact]
    public void ATypoOrAPastThePageCountIsAnError()
    {
        Assert.NotNull(PageChoice.Resolve(PageSet.Typed, "", 6).Error);
        Assert.NotNull(PageChoice.Resolve(PageSet.Typed, "2-x", 6).Error);
        Assert.NotNull(PageChoice.Resolve(PageSet.Typed, "9", 6).Error);
    }

    [Fact]
    public void TargetsDropRepeatsAndPagesThatAreNotThere()
    {
        Assert.Equal([0, 2], PageChoice.Targets([2, 0, 2, 7, -1], 3));
        Assert.Equal([0, 1, 2], PageChoice.Targets(null, 3));
        Assert.Empty(PageChoice.Targets([], 3));
    }

    [Fact]
    public void ARunsPagesReadBackAsARange()
    {
        Assert.Equal("1-3, 5", PageChoice.Describe([0, 1, 2, 4]));
        Assert.Equal("2", PageChoice.Describe([1]));
        Assert.Equal("1, 3, 5", PageChoice.Describe([4, 0, 2]));
    }
}
