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

    [Fact]
    public void AWordNearACornerOfATurnedPageMovesAboutTheCentre()
    {
        // 2550 by 3300 read at 2 degrees clockwise: the top-left word's baseline start moves about 68 px, and its size stays.
        double t = 2 * Math.PI / 180;
        var box = WindowsOcr.Turned(100, 100, 340, 30, t, 1275, 1650);

        double dx = 100 - 1275, dy = 130 - 1650;
        Assert.Equal(1275 + dx * Math.Cos(t) - dy * Math.Sin(t), box.X, 6);
        Assert.Equal(1650 + dx * Math.Sin(t) + dy * Math.Cos(t), box.Bottom, 6);
        Assert.Equal((340, 30), (box.Width, box.Height));
        Assert.InRange(box.X - 100, 50, 80);
    }

    [Fact]
    public void AWordAtTheCentreStaysPut()
    {
        var box = WindowsOcr.Turned(550, 400, 100, 20, 0.1, 550, 420);

        Assert.Equal(550, box.X, 6);
        Assert.Equal(420, box.Bottom, 6);
    }
}
