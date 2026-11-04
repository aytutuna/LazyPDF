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
}
