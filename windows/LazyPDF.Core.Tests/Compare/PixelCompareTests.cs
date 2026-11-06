using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PixelCompareTests
{
    internal sealed class Canvas(int width, int height)
    {
        public int Width { get; } = width;
        public int Height { get; } = height;
        public byte[] Gray { get; } = Enumerable.Repeat((byte)255, width * height).ToArray();

        public void Fill(int x, int y, int w, int h, byte value)
        {
            for (int yy = Math.Max(0, y); yy < Math.Min(Height, y + h); yy++)
            {
                for (int xx = Math.Max(0, x); xx < Math.Min(Width, x + w); xx++) Gray[yy * Width + xx] = value;
            }
        }

        public PdfRgbaImage ToImage()
        {
            var rgba = new byte[Width * Height * 4];
            for (int i = 0; i < Gray.Length; i++) (rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3]) = (Gray[i], Gray[i], Gray[i], 255);
            return new PdfRgbaImage(Width, Height, rgba);
        }
    }

    /// <summary>A page of text-like lines of word blocks, the same for the same seed; <paramref name="scale"/> grows it.</summary>
    internal static Canvas Text(int width = 600, int height = 800, double scale = 1, int seed = 5)
    {
        var random = new Random(seed);
        var canvas = new Canvas((int)(width * scale), (int)(height * scale));
        for (int line = 0; line < 28; line++)
        {
            int x = 60;
            while (x < 520)
            {
                int w = random.Next(20, 70);
                if (x + w > 540) break;
                canvas.Fill((int)(x * scale), (int)((70 + line * 24) * scale), (int)(w * scale), (int)(10 * scale), 20);
                x += w + 10;
            }
        }
        return canvas;
    }

    /// <summary>The picture seen through a turn by <paramref name="degrees"/> clockwise and a shift, as a scanner would make it.</summary>
    internal static PdfRgbaImage Scan(Canvas source, double degrees, int shiftX, int shiftY, int noise = 0)
    {
        var result = new Canvas(source.Width, source.Height);
        double a = degrees * Math.PI / 180, cx = (source.Width - 1) / 2.0, cy = (source.Height - 1) / 2.0;
        var random = new Random(3);
        for (int y = 0; y < source.Height; y++)
        {
            for (int x = 0; x < source.Width; x++)
            {
                double px = x - cx - shiftX, py = y - cy - shiftY;
                int sx = (int)Math.Round(px * Math.Cos(a) + py * Math.Sin(a) + cx), sy = (int)Math.Round(-px * Math.Sin(a) + py * Math.Cos(a) + cy);
                int value = sx < 0 || sy < 0 || sx >= source.Width || sy >= source.Height ? 255 : source.Gray[sy * source.Width + sx];
                result.Gray[y * source.Width + x] = (byte)Math.Clamp(value + (noise == 0 ? 0 : random.Next(-noise, noise + 1)), 0, 255);
            }
        }
        return result.ToImage();
    }

    [Fact]
    public void IdenticalPagesHaveNoDifferences()
    {
        var page = Text().ToImage();
        var result = PixelComparer.Compare(page, page, 72);
        Assert.Empty(result.Differences);
        Assert.Equal(1.0, result.Similarity);
        Assert.Equal((600, 800), (result.Overlay.Width, result.Overlay.Height));
        Assert.Equal(0, result.Alignment.ShiftX);
    }

    [Fact]
    public void TwoBlankPagesAreSimilar()
    {
        var blank = new Canvas(100, 100).ToImage();
        var result = PixelComparer.Compare(blank, blank, 72);
        Assert.Equal(1.0, result.Similarity);
        Assert.Empty(result.Differences);
    }

    [Fact]
    public void AddedBlockIsOneRegionInPoints()
    {
        var before = Text();
        var after = Text();
        after.Fill(200, 740, 80, 14, 0);
        var result = PixelComparer.Compare(before.ToImage(), after.ToImage(), 72);
        var difference = Assert.Single(result.Differences);
        Assert.InRange(difference.Region.X, 198, 202);
        Assert.InRange(difference.Region.Y, 738, 742);
        Assert.InRange(difference.Region.Width, 78, 82);
        Assert.InRange(difference.Region.Height, 12, 16);
        Assert.InRange(difference.Pixels, 80 * 14 - 200, 80 * 14);
        Assert.InRange(result.Similarity, 0.9, 0.999);
        // The overlay shows ink only the new page has in green.
        int at = (746 * 600 + 240) * 4;
        Assert.Equal((0, 170, 0), (result.Overlay.Rgba[at], result.Overlay.Rgba[at + 1], result.Overlay.Rgba[at + 2]));
    }

    [Fact]
    public void RemovedBlockIsRedInTheOverlay()
    {
        var before = Text();
        var after = Text();
        before.Fill(200, 740, 80, 14, 0);
        var result = PixelComparer.Compare(before.ToImage(), after.ToImage(), 72);
        Assert.Single(result.Differences);
        int at = (746 * 600 + 240) * 4;
        Assert.Equal((220, 0, 0), (result.Overlay.Rgba[at], result.Overlay.Rgba[at + 1], result.Overlay.Rgba[at + 2]));
    }

    [Fact]
    public void RegionsFollowTheResolution()
    {
        var before = Text();
        var after = Text();
        after.Fill(200, 740, 80, 14, 0);
        var region = Assert.Single(PixelComparer.Compare(before.ToImage(), after.ToImage(), 144).Differences).Region;
        Assert.InRange(region.X, 99, 101);
        Assert.InRange(region.Width, 39, 41);
    }

    [Fact]
    public void SeparateChangesAreSeparateRegions()
    {
        var before = Text();
        var after = Text();
        after.Fill(100, 740, 30, 12, 0);
        after.Fill(400, 40, 30, 12, 0);
        var result = PixelComparer.Compare(before.ToImage(), after.ToImage(), 72);
        Assert.Equal(2, result.Differences.Count);
    }

    [Fact]
    public void DifferencesBelowTheThresholdAreIgnored()
    {
        var before = Text();
        var after = Text();
        after.Fill(200, 740, 80, 14, 230);
        Assert.Empty(PixelComparer.Compare(before.ToImage(), after.ToImage(), 72).Differences);
        Assert.Single(PixelComparer.Compare(before.ToImage(), after.ToImage(), 72, new PixelOptions(Threshold: 10)).Differences);
    }

    [Fact]
    public void ScanNoiseIsNotADifference()
    {
        var page = Text();
        var result = PixelComparer.Compare(page.ToImage(), Scan(page, 0, 0, 0, noise: 3), 72);
        Assert.Empty(result.Differences);
        Assert.Equal(1.0, result.Similarity);
    }

    [Fact]
    public void OnePixelShiftWithinToleranceIsNoDifference()
    {
        var page = Text();
        var options = new PixelOptions(Align: false);
        Assert.Empty(PixelComparer.Compare(page.ToImage(), Scan(page, 0, 1, 0), 72, options).Differences);
        Assert.NotEmpty(PixelComparer.Compare(page.ToImage(), Scan(page, 0, 4, 0), 72, options).Differences);
    }

    [Fact]
    public void ShiftedScanIsAlignedFirst()
    {
        var page = Text();
        var shifted = Scan(page, 0, 7, -5, noise: 3);
        var plain = PixelComparer.Compare(page.ToImage(), shifted, 72, new PixelOptions(Align: false));
        var aligned = PixelComparer.Compare(page.ToImage(), shifted, 72);
        Assert.True(plain.Similarity < 0.6, plain.Similarity.ToString());
        Assert.InRange(aligned.Similarity, 0.97, 1);
        Assert.InRange(aligned.Alignment.ShiftX, 6, 8);
        Assert.InRange(aligned.Alignment.ShiftY, -6, -4);
        Assert.InRange(aligned.Alignment.Degrees, -0.2, 0.2);
        Assert.True(aligned.Differences.Count < 5);
    }

    [Fact]
    public void RotatedAndShiftedScanIsAligned()
    {
        var page = Text();
        var scan = Scan(page, 0.8, 6, 4, noise: 2);
        var plain = PixelComparer.Compare(page.ToImage(), scan, 72, new PixelOptions(Align: false));
        var aligned = PixelComparer.Compare(page.ToImage(), scan, 72);
        Assert.True(plain.Similarity < 0.6, plain.Similarity.ToString());
        Assert.InRange(aligned.Similarity, 0.85, 1);
        Assert.InRange(aligned.Alignment.Degrees, 0.5, 1.1);
        Assert.InRange(aligned.Alignment.ShiftX, 4, 8);
        Assert.InRange(aligned.Alignment.ShiftY, 2, 6);
    }

    [Fact]
    public void ScanTurnedTheOtherWayIsAlignedToo()
    {
        var page = Text();
        var aligned = PixelComparer.Compare(page.ToImage(), Scan(page, -1.2, -9, 3), 72);
        Assert.InRange(aligned.Similarity, 0.8, 1);
        Assert.InRange(aligned.Alignment.Degrees, -1.6, -0.8);
    }

    [Fact]
    public void ChangeInAShiftedScanIsStillFound()
    {
        var page = Text();
        var changed = Text();
        changed.Fill(100, 420, 120, 14, 0);
        var result = PixelComparer.Compare(page.ToImage(), Scan(changed, 0.5, 5, -3), 72);
        Assert.NotEmpty(result.Differences);
        var biggest = result.Differences.MaxBy(d => d.Pixels)!;
        Assert.InRange(biggest.Region.X, 95, 125);
        Assert.InRange(biggest.Region.Y, 408, 430);
        Assert.True(biggest.Region.Width > 90);
    }

    [Fact]
    public void PagesOfDifferentSizesAreFitted()
    {
        var small = Text();
        var large = Text(scale: 1.25);
        var result = PixelComparer.Compare(small.ToImage(), large.ToImage(), 72);
        Assert.Equal((750, 1000), (result.Overlay.Width, result.Overlay.Height));
        Assert.InRange(result.Similarity, 0.8, 1);
    }

    private sealed class FakeRenderer(PdfRgbaImage? image) : IPageRenderer
    {
        public List<(int Page, double Dpi)> Calls { get; } = [];

        public PdfRgbaImage? Render(int pageIndex, double dpi)
        {
            Calls.Add((pageIndex, dpi));
            return image;
        }
    }

    [Fact]
    public void RendererOverloadAsksBothSides()
    {
        var one = new FakeRenderer(Text().ToImage());
        var two = new FakeRenderer(Text().ToImage());
        var result = PixelComparer.Compare(one, 3, two, 5, 100);
        Assert.NotNull(result);
        Assert.Equal([(3, 100.0)], one.Calls);
        Assert.Equal([(5, 100.0)], two.Calls);
    }

    [Fact]
    public void RendererThatCannotDrawGivesNull()
    {
        Assert.Null(PixelComparer.Compare(new FakeRenderer(null), 0, new FakeRenderer(Text().ToImage()), 0, 72));
    }

    [Fact]
    public void EmptyOrShortImagesAreRefused()
    {
        var good = Text(100, 100).ToImage();
        Assert.Throws<ArgumentException>(() => PixelComparer.Compare(new PdfRgbaImage(0, 0, []), good, 72));
        Assert.Throws<ArgumentException>(() => PixelComparer.Compare(good, new PdfRgbaImage(10, 10, new byte[10]), 72));
    }

    [Fact]
    public void TransparentPixelsCountAsWhite()
    {
        var opaque = new Canvas(50, 50).ToImage();
        var clear = new PdfRgbaImage(50, 50, new byte[50 * 50 * 4]);
        Assert.Empty(PixelComparer.Compare(opaque, clear, 72).Differences);
    }
}
