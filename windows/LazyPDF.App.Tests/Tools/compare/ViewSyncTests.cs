using LazyPDF.App.Tools.Compare;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Which page of one file the other file's view follows to.
public sealed class ViewSyncTests
{
    // Old pages 0 1 2 3 against new pages 0 1 2 3 4: old 1 is gone, new 2 was added.
    private static readonly PagePair[] Pairs =
    [
        new(0, 0, 1, false),
        new(1, -1, 0, false),
        new(2, 1, 0.9, false),
        new(-1, 2, 0, false),
        new(3, 3, 1, false),
        new(-1, 4, 0, false),
    ];

    [Theory]
    [InlineData(0, 0)]
    [InlineData(2, 1)]
    [InlineData(3, 3)]
    public void APairedPageGoesToItsPartner(int old, int partner) => Assert.Equal(partner, ViewSync.Partner(Pairs, old, fromOld: true));

    [Fact]
    public void ARemovedPageGoesToTheNextPageThatSurvived() => Assert.Equal(1, ViewSync.Partner(Pairs, 1, fromOld: true));

    [Fact]
    public void AnAddedPageGoesToTheNextPageOfTheOldFile() => Assert.Equal(3, ViewSync.Partner(Pairs, 2, fromOld: false));

    [Fact]
    public void AnAddedPageAtTheEndFallsBackToThePageBefore() => Assert.Equal(3, ViewSync.Partner(Pairs, 4, fromOld: false));

    [Fact]
    public void APageNoPairNamesHasNoPartner() => Assert.Equal(-1, ViewSync.Partner(Pairs, 9, fromOld: true));
}
