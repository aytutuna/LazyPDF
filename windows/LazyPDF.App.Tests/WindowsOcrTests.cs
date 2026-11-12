using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Windows.Media.Ocr over a page the renderer drew. They run only where an English OCR language is installed.
public sealed class WindowsOcrTests
{
    private static readonly WindowsOcr Ocr = new();

    [Fact]
    public async Task TheWordsOfADrawnPageAreFoundWithBoxes()
    {
        if (!WindowsOcr.IsAvailable("en-US")) return;
        var session = PdfEditSession.Open(Pdfs.Text(line: "Quick brown fox jumps over the lazy dog."));
        using var renderer = new WindowsPageRenderer();
        renderer.Load(session, null);
        var image = renderer.Render(0, 200)!;

        var words = await Ocr.RecognizeAsync(image, "en-US");

        Assert.Contains(words, w => w.Text.Equals("fox", StringComparison.OrdinalIgnoreCase));
        Assert.All(words, w =>
        {
            Assert.InRange(w.Box.X, 0, image.Width);
            Assert.InRange(w.Box.Bottom, 0, image.Height + 1);
        });
    }

    [Fact]
    public async Task ABlankPageHasNoWords()
    {
        if (!WindowsOcr.IsAvailable("en-US")) return;
        var blank = new PdfRgbaImage(300, 300, Enumerable.Repeat((byte)255, 300 * 300 * 4).ToArray());

        Assert.Empty(await Ocr.RecognizeAsync(blank, "en-US"));
    }

    [Fact]
    public async Task ALanguageWindowsDoesNotHaveIsSaidInWords()
    {
        var blank = new PdfRgbaImage(10, 10, new byte[400]);

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Ocr.RecognizeAsync(blank, "tlh"));

        Assert.Contains("tlh", error.Message);
    }

    [Fact]
    public async Task ACancelledRunStops()
    {
        if (!WindowsOcr.IsAvailable("en-US")) return;
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        var blank = new PdfRgbaImage(10, 10, new byte[400]);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Ocr.RecognizeAsync(blank, "en-US", cancel.Token));
    }

    [Fact]
    public void ANonsenseTagIsNotAvailable() => Assert.False(WindowsOcr.IsAvailable("not a language"));

    // 3 by 2 with the top left pixel marked.
    private static PdfRgbaImage Marked()
    {
        var rgba = new byte[3 * 2 * 4];
        rgba[0] = 200;
        return new PdfRgbaImage(3, 2, rgba);
    }

    private static (int X, int Y) MarkAt(PdfRgbaImage image) =>
        Enumerable.Range(0, image.Width * image.Height).Where(i => image.Rgba[i * 4] == 200).Select(i => (i % image.Width, i / image.Width)).Single();

    [Theory]
    [InlineData(1, 2, 3, 1, 0)]
    [InlineData(2, 3, 2, 2, 1)]
    [InlineData(3, 2, 3, 0, 2)]
    [InlineData(4, 3, 2, 0, 0)]
    public void ATurnMovesTheMarkClockwiseAndSwapsTheSizeForQuarterTurns(int turns, int width, int height, int x, int y)
    {
        var turned = WindowsOcr.Turn(Marked(), turns);

        Assert.Equal((width, height), (turned.Width, turned.Height));
        Assert.Equal((x, y), MarkAt(turned));
    }

    [Theory]
    [InlineData(0.1)]
    [InlineData(-0.1)]
    public void ATurnedWordIsBackToItsUprightSizeAtTheBaselineStart(double angle)
    {
        // A 100 by 20 word turned about its bottom-left corner at (200, 300), as seen with y down.
        double cos = Math.Cos(angle), sin = Math.Sin(angle);
        var corners = new[] { (0.0, 0.0), (100.0, 0.0), (0.0, 20.0), (100.0, 20.0) }
            .Select(p => (X: 200 + p.Item1 * cos - p.Item2 * sin, Y: 300 - p.Item1 * sin - p.Item2 * cos)).ToArray();
        double left = corners.Min(c => c.X), top = corners.Min(c => c.Y);
        double right = corners.Max(c => c.X), bottom = corners.Max(c => c.Y);

        var box = WindowsOcr.Deskewed(left, top, right - left, bottom - top, angle);

        Assert.Equal(100, box.Width, 6);
        Assert.Equal(20, box.Height, 6);
        Assert.Equal(200, box.X, 6);
        Assert.Equal(300, box.Bottom, 6);
    }
}
