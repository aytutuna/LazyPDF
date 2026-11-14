using Xunit;

namespace LazyPDF.Core.Tests;

public class Jbig2HalftoneTests
{
    private sealed record Halftone(int Width, int Height, int GridWidth, int GridHeight, int GridX, int GridY, int VectorX, int VectorY,
                                   int Template, bool Mmr, bool Skip, int Op, int DefaultPixel);

    private static List<Bm> Patterns(int count, int width, int height)
    {
        // Pattern i has i of its pixels set, in an order that does not look like the gray ramp.
        var patterns = new List<Bm>();
        for (int i = 0; i < count; i++)
        {
            var bm = new Bm(width, height);
            for (int k = 0; k < Math.Min(i, width * height); k++) bm.Px[(k * 7 + 3) % (width * height)] = 1;
            if (i > width * height) bm.Px[i % (width * height)] ^= 1;
            patterns.Add(bm);
        }
        return patterns;
    }

    private static byte[] PatternSegment(List<Bm> patterns, int template, bool mmr)
    {
        int w = patterns[0].Width, h = patterns[0].Height;
        var collective = new Bm(w * patterns.Count, h);
        for (int i = 0; i < patterns.Count; i++)
        {
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++) collective[i * w + x, y] = patterns[i][x, y];
            }
        }
        byte[] coded;
        if (mmr) coded = CcittEncoder.Encode(collective.Packed(), collective.Width, h);
        else
        {
            var e = new ArithEncoder();
            Jbig2Encode.Generic(e, collective, template, false, template == 0 ? [-w, 0, -3, -1, 2, -2, -2, -2] : [-w, 0]);
            coded = e.Finish();
        }
        return Jbig2Segments.Cat([(byte)((mmr ? 1 : 0) | template << 1), (byte)w, (byte)h], Jbig2Segments.U32(patterns.Count - 1), coded);
    }

    private static long CellX(Halftone t, int m, int n) => ((long)t.GridX + (long)m * t.VectorY + (long)n * t.VectorX) >> 8;

    private static long CellY(Halftone t, int m, int n) => ((long)t.GridY + (long)m * t.VectorX - (long)n * t.VectorY) >> 8;

    /// <summary>The region and the segment data for gray values over the grid.</summary>
    private static (Bm Region, byte[] Data) Region(Halftone t, List<Bm> patterns, int[,] values)
    {
        int w = patterns[0].Width, h = patterns[0].Height;
        var region = new Bm(t.Width, t.Height);
        if (t.DefaultPixel != 0) Array.Fill(region.Px, (byte)1);
        var skip = new Bm(t.GridWidth, t.GridHeight);
        for (int m = 0; m < t.GridHeight; m++)
        {
            for (int n = 0; n < t.GridWidth; n++)
            {
                long x = CellX(t, m, n), y = CellY(t, m, n);
                bool outside = x + w <= 0 || x >= t.Width || y + h <= 0 || y >= t.Height;
                if (t.Skip && outside) skip[n, m] = 1;
                if (outside) continue;
                for (int j = 0; j < h; j++)
                {
                    for (int i = 0; i < w; i++)
                    {
                        int px = (int)x + i, py = (int)y + j;
                        if (px < 0 || py < 0 || px >= t.Width || py >= t.Height) continue;
                        int d = region[px, py], s = patterns[values[m, n]][i, j];
                        region[px, py] = t.Op switch { 0 => d | s, 1 => d & s, 2 => d ^ s, 3 => 1 ^ d ^ s, _ => s };
                    }
                }
            }
        }

        int bits = Jbig2TextEncode.CodeLength(patterns.Count);
        var e = new ArithEncoder();
        var mmrParts = new List<byte[]>();
        int[] at = t.Template == 0 ? [3, -1, -3, -1, 2, -2, -2, -2] : [t.Template == 1 ? 3 : 2, -1];
        for (int j = bits - 1; j >= 0; j--)
        {
            var plane = new Bm(t.GridWidth, t.GridHeight);
            for (int m = 0; m < t.GridHeight; m++)
            {
                for (int n = 0; n < t.GridWidth; n++)
                {
                    int v = skip[n, m] != 0 ? 0 : values[m, n];
                    plane[n, m] = ((v ^ (v >> 1)) >> j) & 1;
                }
            }
            if (t.Mmr) mmrParts.Add(CcittEncoder.Encode(plane.Packed(), t.GridWidth, t.GridHeight));
            else Jbig2Encode.Generic(e, plane, t.Template, false, at, t.Skip ? skip : null);
        }
        byte[] coded = t.Mmr ? [.. mmrParts.SelectMany(p => p)] : e.Finish();
        byte[] data = Jbig2Segments.Cat(
            Jbig2Segments.RegionInfo(t.Width, t.Height),
            [(byte)((t.Mmr ? 1 : 0) | t.Template << 1 | (t.Skip ? 8 : 0) | t.Op << 4 | t.DefaultPixel << 7)],
            Jbig2Segments.U32(t.GridWidth), Jbig2Segments.U32(t.GridHeight), Jbig2Segments.U32(t.GridX), Jbig2Segments.U32(t.GridY),
            Jbig2Segments.U16(t.VectorX), Jbig2Segments.U16(t.VectorY), coded);
        return (region, data);
    }

    private static int[,] Values(Halftone t, int count, int seed)
    {
        var random = new Random(seed);
        var values = new int[t.GridHeight, t.GridWidth];
        for (int m = 0; m < t.GridHeight; m++)
        {
            for (int n = 0; n < t.GridWidth; n++) values[m, n] = random.Next(count);
        }
        return values;
    }

    private static byte[] Stream(Halftone t, List<Bm> patterns, int[,] values, out Bm expected, bool mmrPatterns, int patternTemplate)
    {
        var (region, data) = Region(t, patterns, values);
        expected = region;
        return Jbig2Segments.Cat(
            Jbig2Segments.Segment(0, 48, Jbig2Segments.PageInfo(t.Width, t.Height)),
            Jbig2Segments.Segment(1, 16, PatternSegment(patterns, patternTemplate, mmrPatterns)),
            Jbig2Segments.Segment(2, 22, data, [1]));
    }

    internal static IEnumerable<Jbig2Samples.Sample> Samples()
    {
        var patterns = Patterns(16, 4, 4);
        var plain = new Halftone(60, 40, 15, 10, 0, 0, 1024, 0, 0, false, false, 0, 0);
        yield return new Jbig2Samples.Sample("halftone-arith.bin", Stream(plain, patterns, Values(plain, 16, 1), out var expected, false, 0), expected);
        var mmr = new Halftone(60, 40, 15, 10, 0, 0, 1024, 0, 0, true, false, 0, 0);
        yield return new Jbig2Samples.Sample("halftone-mmr.bin", Stream(mmr, patterns, Values(mmr, 16, 2), out expected, true, 0), expected);
        var skipped = new Halftone(40, 30, 20, 20, -2560, 1280, 700, 400, 1, false, true, 2, 0);
        var small = Patterns(4, 3, 3);
        yield return new Jbig2Samples.Sample("halftone-skip.bin", Stream(skipped, small, Values(skipped, 4, 5), out expected, false, 1), expected);
    }

    [Theory]
    [InlineData(0, false, 16)]
    [InlineData(1, false, 16)]
    [InlineData(2, false, 5)]
    [InlineData(3, false, 2)]
    [InlineData(0, true, 16)]
    [InlineData(2, true, 9)]
    public void HalftoneRegionDrawsPatternsOnAGrid(int template, bool mmr, int patternCount)
    {
        // A grid of 4 by 4 patterns, 1024/256 = 4 pixels apart each way.
        var t = new Halftone(60, 40, 15, 10, 0, 0, 1024, 0, template, mmr, false, 0, 0);
        var patterns = Patterns(patternCount, 4, 4);
        var stream = Stream(t, patterns, Values(t, patternCount, template + 1), out var expected, mmr, template);
        Assert.Equal(expected.Packed(), Jbig2GenericTests.Decode(stream));
    }

    [Theory]
    [InlineData(0, 0, 0)]
    [InlineData(1, 1, 0)]
    [InlineData(2, 0, 1)]
    [InlineData(3, 0, 0)]
    [InlineData(4, 1, 1)]
    public void CombinationOperatorsAndDefaultPixel(int op, int defaultPixel, int template)
    {
        var t = new Halftone(50, 30, 12, 8, 300, -400, 900, 200, template, false, false, op, defaultPixel);
        var patterns = Patterns(8, 5, 3);
        var stream = Stream(t, patterns, Values(t, 8, 9), out var expected, false, 0);
        Assert.Equal(expected.Packed(), Jbig2GenericTests.Decode(stream));
    }

    [Fact]
    public void SkippedCellsOutsideTheRegionAreNotCoded()
    {
        // The grid is turned and reaches past the region, so cells fall outside it.
        var t = new Halftone(40, 30, 20, 20, -2560, 1280, 700, 400, 0, false, true, 0, 0);
        var patterns = Patterns(4, 3, 3);
        var stream = Stream(t, patterns, Values(t, 4, 5), out var expected, false, 0);
        Assert.Equal(expected.Packed(), Jbig2GenericTests.Decode(stream));
    }

    [Fact]
    public void SinglePatternNeedsNoPlanes()
    {
        var t = new Halftone(20, 20, 5, 5, 0, 0, 1024, 0, 0, false, false, 0, 0);
        var patterns = Patterns(1, 4, 4);
        patterns[0] = Bm.Text(4, 4, 3);
        var stream = Stream(t, patterns, new int[5, 5], out var expected, false, 0);
        Assert.Equal(expected.Packed(), Jbig2GenericTests.Decode(stream));
    }
}
