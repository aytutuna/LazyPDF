using System.Windows;
using LazyPDF.App.Viewer;
using Xunit;

namespace LazyPDF.App.Tests;

// Cutting a page into the tiles the renderer is asked for.
public sealed class TilePlanTests
{
    private static int Exact(int pixels) => pixels;

    // Sizes the way Windows makes them: a request in whole units of 1.4 pixels.
    private static int Scaled(int pixels) => (int)Math.Round(Math.Max(1, Math.Round(pixels / 1.4)) * 1.4);

    private static List<TileSpec> Cover(Size page, double scale, Rect area, Func<int, int>? reachable = null) =>
        TilePlan.Cover(3, 7, PageTint.None, page, scale, area, reachable ?? Exact);

    [Fact]
    public void AWholePageIsAGridOfTilesThatMeetTheEdges()
    {
        var tiles = Cover(new Size(612, 792), 2, new Rect(0, 0, 1224, 1584));

        Assert.Equal(3 * 4, tiles.Count);
        Assert.All(tiles, t => Assert.Equal((3, 7), (t.Key.Page, t.Key.Version)));
        var last = tiles[^1];
        Assert.Equal(2 * 512, last.X);
        Assert.Equal(3 * 512, last.Y);
        Assert.Equal(1224 - 1024, last.Width);
        Assert.Equal(1584 - 1536, last.Height);
        Assert.Equal(1584, tiles.Where(t => t.Key.Column == 0).Sum(t => t.Height));
    }

    [Fact]
    public void OnlyTheTilesTheAreaMeetsAreWanted()
    {
        var tiles = Cover(new Size(612, 792), 2, new Rect(600, 520, 100, 10));

        Assert.Equal([(1, 1)], tiles.Select(t => (t.Key.Column, t.Key.Row)));
    }

    [Fact]
    public void AnAreaOffThePageGivesNothing()
    {
        Assert.Empty(Cover(new Size(100, 100), 1, new Rect(500, 500, 10, 10)));
        Assert.Empty(Cover(new Size(100, 100), 1, Rect.Empty));
    }

    [Fact]
    public void AnAreaWiderThanThePageIsCutToIt()
    {
        var tiles = Cover(new Size(100, 100), 1, new Rect(-50, -50, 900, 900));

        Assert.Single(tiles);
        Assert.Equal((100, 100), (tiles[0].Width, tiles[0].Height));
    }

    [Fact]
    public void TheGridStepIsTheNearestSizeTheRendererMakes()
    {
        static int Coarse(int pixels) => (pixels + 7) / 8 * 8 + 3;

        var tiles = Cover(new Size(612, 792), 2, new Rect(0, 0, 1224, 1584), Coarse);

        Assert.Equal(515, tiles.First(t => t.Key.Column == 1).X);
        Assert.Equal(515, tiles.First(t => t.Key.Row == 1).Y);
    }

    [Fact]
    public void ALastTileReachesTheEdgeEvenWhenItsSizeIsNotMadeExactly()
    {
        for (int width = 1; width < 700; width++)
        {
            var tiles = Cover(new Size(width, 50), 1, new Rect(0, 0, width, 50), Scaled);

            var last = tiles.Where(t => t.Key.Row == 0).Last();
            Assert.True(last.X + Scaled(last.Width) >= width, $"width {width}");
        }
    }

    [Fact]
    public void TheKeyOfATileNamesItsPlaceAndScale()
    {
        var tile = Cover(new Size(612, 792), 1.5, new Rect(600, 0, 10, 10))[0];

        Assert.Equal(new TileKey(3, 7, 1.5, 1, 0, PageTint.None), tile.Key);
        Assert.False(tile.Key.IsPreview);
    }

    [Fact]
    public void ThePreviewIsTheWholePageAtALowScale()
    {
        var preview = TilePlan.Preview(2, 5, PageTint.Dark, new Size(600, 800));

        Assert.True(preview.Key.IsPreview);
        Assert.Equal(TilePlan.PreviewScale(new Size(600, 800)), preview.Key.Scale);
        Assert.Equal(TilePlan.PreviewSide, preview.Height);
        Assert.Equal(480, preview.Width);
        Assert.Equal(PageTint.Dark, preview.Key.Tint);
    }

    [Fact]
    public void ATileLiesWhereItsPixelsAreOnThePage()
    {
        var tile = Cover(new Size(612, 792), 2, new Rect(600, 520, 100, 10))[0];

        var rect = TilePlan.PointsRect(tile, 512, 512);

        Assert.Equal(new Rect(256, 256, 256, 256), rect);
    }
}
