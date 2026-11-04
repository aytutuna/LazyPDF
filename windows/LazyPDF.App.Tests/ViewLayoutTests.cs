using System.Windows;
using LazyPDF.App.Viewer;
using Xunit;

namespace LazyPDF.App.Tests;

// Where the pages sit: one column or facing pages, a cover, continuous or one spread at a time.
public sealed class PageLayoutTests
{
    private static readonly Size Viewport = new(800, 600);

    private static Size[] Pages(int count, double width = 100, double height = 200) => [.. Enumerable.Repeat(new Size(width, height), count)];

    private static LayoutOptions Options(int columns = 1, bool cover = false, bool continuous = true, int rotation = 0, double scale = 1, double ppd = 1) =>
        new(columns, cover, continuous, rotation, scale, Viewport, ppd);

    [Fact]
    public void PagesOfOneColumnAreStackedAndCentred()
    {
        var layout = ViewLayout.Build(Pages(3), Options());

        var first = layout.PageRect(0);
        var second = layout.PageRect(1);
        Assert.Equal(new Size(100, 200), first.Size);
        Assert.Equal((800 - 100) / 2.0, first.Left);
        Assert.Equal(ViewLayout.Margin, first.Top);
        Assert.Equal(first.Bottom + ViewLayout.Gap, second.Top);
        Assert.Equal(ViewLayout.Margin + 3 * 200 + 2 * ViewLayout.Gap + ViewLayout.Margin, layout.Extent.Height);
    }

    [Fact]
    public void ThePagesAreScaledByTheScale()
    {
        var layout = ViewLayout.Build(Pages(1), Options(scale: 2.5));

        Assert.Equal(new Size(250, 500), layout.PageRect(0).Size);
    }

    [Fact]
    public void AWidePageWidensTheScrolledAreaPastTheViewport()
    {
        var layout = ViewLayout.Build(Pages(1, width: 2000), Options());

        Assert.Equal(2000 + 2 * ViewLayout.Margin, layout.Extent.Width);
        Assert.Equal(ViewLayout.Margin, layout.PageRect(0).Left);
    }

    [Theory]
    [InlineData(90)]
    [InlineData(270)]
    public void ASidewaysRotationLaysOutTheSwappedSize(int rotation)
    {
        var layout = ViewLayout.Build(Pages(2), Options(rotation: rotation));

        Assert.Equal(new Size(200, 100), layout.PageRect(1).Size);
    }

    [Fact]
    public void FacingPagesSitSideBySide()
    {
        var layout = ViewLayout.Build(Pages(4), Options(columns: 2));

        var (a, b, c) = (layout.PageRect(0), layout.PageRect(1), layout.PageRect(2));
        Assert.Equal(a.Top, b.Top);
        Assert.Equal(a.Right + ViewLayout.Gap, b.Left);
        Assert.True(c.Top > a.Bottom);
        Assert.Equal(c.Left, a.Left);
    }

    [Fact]
    public void ACoverStandsAloneOnTheRightAndTheNextTwoFace()
    {
        var layout = ViewLayout.Build(Pages(4), Options(columns: 2, cover: true));

        var (cover, two, three, four) = (layout.PageRect(0), layout.PageRect(1), layout.PageRect(2), layout.PageRect(3));
        Assert.Equal(two.Right + ViewLayout.Gap, three.Left);
        Assert.Equal(two.Top, three.Top);
        Assert.True(two.Top > cover.Bottom);
        Assert.Equal(three.Left, cover.Left);
        Assert.Equal(two.Left, four.Left);
    }

    [Fact]
    public void ALastPageAloneKeepsTheLeftPlace()
    {
        var layout = ViewLayout.Build(Pages(3), Options(columns: 2));

        Assert.Equal(layout.PageRect(0).Left, layout.PageRect(2).Left);
    }

    [Theory]
    [InlineData(1, false, 5, 5)]
    [InlineData(2, false, 5, 3)]
    [InlineData(2, true, 5, 3)]
    [InlineData(2, true, 4, 3)]
    [InlineData(2, false, 4, 2)]
    public void TheSpreadsAreCounted(int columns, bool cover, int pages, int spreads) =>
        Assert.Equal(spreads, ViewLayout.SpreadsOf(columns, cover, pages));

    [Theory]
    [InlineData(true, 0, 0, 0)]
    [InlineData(true, 1, 1, 2)]
    [InlineData(true, 2, 3, 4)]
    [InlineData(false, 0, 0, 1)]
    [InlineData(false, 1, 2, 3)]
    public void ASpreadHoldsItsPagesInOrder(bool cover, int spread, int first, int last)
    {
        var (a, b) = ViewLayout.PagesOf(2, cover, spread, 6);

        Assert.Equal(first, a);
        Assert.Equal(last, b);
        Assert.Equal(spread, ViewLayout.SpreadOf(2, cover, first));
    }

    [Fact]
    public void APagedLayoutHoldsOnlyTheSpreadAskedFor()
    {
        var layout = ViewLayout.Build(Pages(6), Options(columns: 2, continuous: false), spread: 1);

        Assert.True(layout.Contains(2));
        Assert.True(layout.Contains(3));
        Assert.False(layout.Contains(1));
        Assert.Equal(1, layout.FirstSpread);
        Assert.Equal(1, layout.LastSpread);
        Assert.Equal(Viewport.Height, layout.Extent.Height);
        Assert.Equal(Rect.Empty, layout.PageRect(0));
    }

    [Fact]
    public void ASpreadAskedForPastTheEndIsTheLast()
    {
        var layout = ViewLayout.Build(Pages(3), Options(continuous: false), spread: 9);

        Assert.True(layout.Contains(2));
    }

    [Fact]
    public void PositionsAreWholeDevicePixels()
    {
        var layout = ViewLayout.Build(Pages(3, 101.3, 187.7), Options(scale: 1.37, ppd: 1.25));

        foreach (int page in new[] { 0, 1, 2 })
        {
            var r = layout.PageRect(page);
            foreach (double v in new[] { r.Left, r.Top, r.Width, r.Height }) Assert.Equal(Math.Round(v * 1.25), v * 1.25, 6);
        }
    }

    [Fact]
    public void ThePagesInAnAreaAreTheOnesItMeets()
    {
        var layout = ViewLayout.Build(Pages(10), Options());
        var second = layout.PageRect(1);

        Assert.Equal([1], layout.PagesIn(new Rect(0, second.Top + 10, 800, 20)));
        Assert.Equal([3, 4], layout.PagesIn(new Rect(0, layout.PageRect(3).Top + 150, 800, 150)));
    }

    [Fact]
    public void APointOnAPageFindsItAndAPointInTheGapDoesNot()
    {
        var layout = ViewLayout.Build(Pages(3), Options());
        var first = layout.PageRect(0);

        Assert.Equal(0, layout.PageAt(new Point(first.Left + 5, first.Top + 5)));
        Assert.Equal(-1, layout.PageAt(new Point(first.Left + 5, first.Bottom + ViewLayout.Gap / 2)));
        Assert.Equal(-1, layout.PageAt(new Point(1, 1)));
    }

    [Fact]
    public void TheNearestPageOfAPointInTheGapIsTheCloserOne()
    {
        var layout = ViewLayout.Build(Pages(3), Options());
        double gap = layout.PageRect(0).Bottom + 2;

        Assert.Equal(0, layout.NearestPage(new Point(400, gap)));
        Assert.Equal(1, layout.NearestPage(new Point(400, gap + 8)));
        Assert.Equal(2, layout.NearestPage(new Point(400, 100_000)));
    }

    [Fact]
    public void ThePageWithTheMostInViewIsTheCurrentOne()
    {
        var layout = ViewLayout.Build(Pages(5), Options());
        var third = layout.PageRect(2);

        Assert.Equal(2, layout.MostVisible(new Rect(0, third.Top - 20, 800, 300)));
        Assert.Equal(1, layout.MostVisible(new Rect(0, layout.PageRect(1).Top + 20, 800, 100)));
        Assert.Equal(0, layout.MostVisible(new Rect(0, 0, 800, 100)));
    }

    [Fact]
    public void NoPagesGiveAnEmptyLayout()
    {
        var layout = ViewLayout.Build([], Options());

        Assert.Equal(0, layout.PageCount);
        Assert.Empty(layout.PagesIn(new Rect(0, 0, 100, 100)));
        Assert.Equal(-1, layout.PageAt(new Point(1, 1)));
    }
}
