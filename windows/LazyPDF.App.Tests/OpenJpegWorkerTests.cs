using System.Diagnostics;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.App.Tests.JpxMaker;

namespace LazyPDF.App.Tests;

// The decode child: what a hostile file or a dying process costs, and that decoding goes on afterwards.
public sealed partial class OpenJpegTests
{
    private static readonly TimeSpan Short = TimeSpan.FromSeconds(2);

    private static byte[] Small(int seed) => Encode(8, 8, Gray, false, false, new Comp(8, [.. Enumerable.Range(0, 64).Select(i => (i * 3 + seed) % 256)]));

    private static void AssertStillDecodes()
    {
        var image = Read(Small(5));
        for (int i = 0; i < 64; i++) Assert.Equal((i * 3 + 5) % 256, image.Rgba[i * 4]);
    }

    private static void AssertKilled(byte[] bomb)
    {
        var old = JpxWorker.Limit;
        JpxWorker.Limit = Short;
        try
        {
            var watch = Stopwatch.StartNew();
            Assert.Null(OpenJpeg.Decode(bomb));
            Assert.True(watch.Elapsed < Short + TimeSpan.FromSeconds(10), watch.Elapsed.ToString());
        }
        finally
        {
            JpxWorker.Limit = old;
        }
        AssertStillDecodes();
    }

    [Fact]
    public void ADecodeThroughTheChildGivesTheSamePixels()
    {
        int kills = JpxWorker.Kills;
        int[] r = Ramp(64, 255), g = [.. r.Reverse()], b = [.. Enumerable.Range(0, 64).Select(i => i % 8 * 30)];
        var image = Read(Encode(8, 8, Srgb, true, true, new Comp(8, r), new Comp(8, g), new Comp(8, b)));

        Assert.Equal((8, 8), (image.Width, image.Height));
        for (int i = 0; i < 64; i++) Assert.Equal([r[i], g[i], b[i], 255], image.Rgba[(i * 4)..(i * 4 + 4)].Select(v => (int)v));
        Assert.Equal(kills, JpxWorker.Kills);
    }

    [Fact]
    public void AChildThatExitsGivesNullAndTheNextDecodeStartsANewOne()
    {
        AssertStillDecodes();
        int kills = JpxWorker.Kills;

        Assert.Null(JpxWorker.Request(JpxChild.Crash, 0, []));

        Assert.Equal(kills + 1, JpxWorker.Kills);
        AssertStillDecodes();
    }

    [Fact]
    public void AChildThatNeverAnswersIsKilledAtTheLimit()
    {
        AssertStillDecodes();
        int kills = JpxWorker.Kills;
        var old = JpxWorker.Limit;
        JpxWorker.Limit = Short;
        try
        {
            var watch = Stopwatch.StartNew();
            Assert.Null(JpxWorker.Request(JpxChild.Hang, 0, []));
            Assert.InRange(watch.Elapsed, Short - TimeSpan.FromMilliseconds(200), Short + TimeSpan.FromSeconds(8));
        }
        finally
        {
            JpxWorker.Limit = old;
        }

        Assert.Equal(kills + 1, JpxWorker.Kills);
        AssertStillDecodes();
    }

    [Fact]
    public void AChildOverTheMemoryCapIsKilled()
    {
        long cap = JpxWorker.MemoryCap;
        JpxWorker.Reset();
        JpxWorker.MemoryCap = 400L << 20;
        try
        {
            // The runtime itself fits in the cap; 800 MB on top of it does not.
            Assert.NotNull(OpenJpeg.Decode(Small(1)));
            int kills = JpxWorker.Kills;
            Assert.Null(JpxWorker.Request(JpxChild.Allocate, 800, []));
            Assert.Equal(kills + 1, JpxWorker.Kills);
        }
        finally
        {
            JpxWorker.MemoryCap = cap;
            JpxWorker.Reset();
        }
        AssertStillDecodes();
    }

    [Fact]
    public void CallersAtTheSameTimeTakeTurnsAndEachGetsItsOwnPicture()
    {
        byte[][] files = [.. Enumerable.Range(0, 16).Select(Small)];
        var results = new PdfRgbaImage?[files.Length];
        Parallel.For(0, results.Length, new ParallelOptions { MaxDegreeOfParallelism = 8 }, i => results[i] = OpenJpeg.Decode(files[i]));

        for (int i = 0; i < results.Length; i++)
        {
            var image = Assert.IsType<PdfRgbaImage>(results[i]);
            for (int k = 0; k < 64; k++) Assert.Equal((k * 3 + i) % 256, image.Rgba[k * 4]);
        }
    }

    [Fact]
    public void ManyLayersOfPrecinctsOfOneSampleAreKilledAtTheLimit() =>
        AssertKilled(Hostile(92, 92, 92, 0, true, layers: 65535));

    [Fact]
    public void ACocBeforeTheCodIsKilledAtTheLimit() =>
        AssertKilled(Hostile(92, 92, 92, 0, false, layers: 65535, beforeCod: Coc(0, true)));

    [Fact]
    public void ACocBehindAMarkerNobodyKnowsIsKilledAtTheLimit() =>
        AssertKilled(Hostile(92, 92, 92, 0, false, layers: 65535, extra: [.. Be16(0xFF64), .. Be16(6), 1, 2, 3, 4, .. Coc(0, true)]));

    // A 600 dpi A4 scan has some 8000 tiles of 64 x 64; this is a smaller picture with the same layers and many tiles, which the
    // packet bound of the earlier rounds would have had to count.
    [Fact]
    public void AManyLayerPictureInSmallTilesDecodesThroughTheChild()
    {
        var random = new Random(11);
        int[] Plane() => [.. Enumerable.Range(0, 1024 * 768).Select(_ => random.Next(256))];
        int[] r = Plane(), g = Plane(), b = Plane();
        var image = Read(TiledLayered(1024, 768, 64, 30, new Comp(8, r), new Comp(8, g), new Comp(8, b)));

        Assert.Equal((1024, 768), (image.Width, image.Height));
        for (int i = 0; i < r.Length; i += 97) Assert.Equal([r[i], g[i], b[i], 255], image.Rgba[(i * 4)..(i * 4 + 4)].Select(v => (int)v));
    }
}
