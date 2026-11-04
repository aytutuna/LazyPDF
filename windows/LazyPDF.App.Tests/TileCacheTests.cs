using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.App.Viewer;
using Xunit;

namespace LazyPDF.App.Tests;

// The pictures kept for the pages, least recently used first out once they pass the budget.
public sealed class TileCacheTests
{
    // A 50 by 50 picture is 10,000 bytes.
    private static BitmapSource Picture() => BitmapSource.Create(50, 50, 96, 96, PixelFormats.Bgr32, null, new byte[50 * 50 * 4], 200);

    private static TileKey Key(int page, int column = 0) => new(page, 0, 1, column, 0, PageTint.None);

    [Fact]
    public void APictureAddedCanBeFoundAndCounted()
    {
        var cache = new TileCache(1_000_000);

        cache.Add(Key(1), Picture());

        Assert.True(cache.Contains(Key(1)));
        Assert.NotNull(cache.Get(Key(1)));
        Assert.Equal(10_000, cache.Bytes);
        Assert.Equal(1, cache.Count);
    }

    [Fact]
    public void TheLeastRecentlyUsedGoFirstWhenTheBudgetIsPassed()
    {
        var cache = new TileCache(25_000);
        cache.Add(Key(1), Picture());
        cache.Add(Key(2), Picture());
        cache.Get(Key(1));

        cache.Add(Key(3), Picture());

        Assert.True(cache.Contains(Key(1)));
        Assert.False(cache.Contains(Key(2)));
        Assert.True(cache.Contains(Key(3)));
        Assert.Equal(20_000, cache.Bytes);
    }

    [Fact]
    public void LookingWithoutTouchingDoesNotSaveAPicture()
    {
        var cache = new TileCache(25_000);
        cache.Add(Key(1), Picture());
        cache.Add(Key(2), Picture());
        cache.Peek(Key(1));

        cache.Add(Key(3), Picture());

        Assert.False(cache.Contains(Key(1)));
    }

    [Fact]
    public void ThePictureJustAddedStaysEvenIfItAloneIsOverTheBudget()
    {
        var cache = new TileCache(5_000);

        cache.Add(Key(1), Picture());

        Assert.True(cache.Contains(Key(1)));
        cache.Add(Key(2), Picture());
        Assert.Equal([Key(2)], Enumerable.Range(1, 2).SelectMany(cache.Keys));
    }

    [Fact]
    public void AddingTheSameKeyAgainReplacesItAndCountsItOnce()
    {
        var cache = new TileCache(1_000_000);

        cache.Add(Key(1), Picture());
        cache.Add(Key(1), Picture());

        Assert.Equal(1, cache.Count);
        Assert.Equal(10_000, cache.Bytes);
    }

    [Fact]
    public void TheKeysOfAPageAreListedAndRemovedTogether()
    {
        var cache = new TileCache(1_000_000);
        cache.Add(Key(1, 0), Picture());
        cache.Add(Key(1, 1), Picture());
        cache.Add(Key(2, 0), Picture());

        Assert.Equal(2, cache.Keys(1).Count);

        cache.RemoveWhere(1, k => k.Column == 1);

        Assert.Equal([Key(1, 0)], cache.Keys(1));
        Assert.Equal(20_000, cache.Bytes);
    }

    [Fact]
    public void ClearingEmptiesIt()
    {
        var cache = new TileCache(1_000_000);
        cache.Add(Key(1), Picture());

        cache.Clear();

        Assert.Equal(0, cache.Count);
        Assert.Equal(0, cache.Bytes);
        Assert.Empty(cache.Keys(1));
    }
}
