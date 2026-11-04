using LazyPDF.App.Services;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// A layer toggled in the view is drawn from a copy of the file; the file and its session stay as they are.
public sealed class DisplayCopyTests
{
    private static bool IsDark(PdfRgbaImage image) => image.Rgba[(image.Height / 2 * image.Width + image.Width / 2) * 4] < 64;

    [Fact]
    public async Task TheFileDrawsItsLayerAndTheCopyWithTheLayerOffDoesNot()
    {
        byte[] bytes = LayeredPdf.Make();
        using var original = new WindowsPageRenderer();
        original.Load(PdfEditSession.Open(bytes), null);

        using var copy = DisplayCopy.Create(bytes, null, [new(LayeredPdf.BlackBox, false)])!.Renderer;

        Assert.True(IsDark((await original.RenderAsync(0, 36))!));
        Assert.False(IsDark((await copy.RenderAsync(0, 36))!));
    }

    [Fact]
    public void TheCopyReadsTheLayerAsOffAndTheSessionItWasMadeFromAsOn()
    {
        byte[] bytes = LayeredPdf.Make();
        var session = PdfEditSession.Open(bytes);

        var copy = DisplayCopy.Create(bytes, null, [new(LayeredPdf.BlackBox, false)])!;

        Assert.False(PdfLayers.Read(copy.Session.Document).Layers.First(l => l.Reference.Equals(LayeredPdf.BlackBox)).IsOn);
        Assert.True(PdfLayers.Read(session.Document).Layers.First(l => l.Reference.Equals(LayeredPdf.BlackBox)).IsOn);
        Assert.False(session.IsDirty);
        copy.Renderer.Dispose();
    }

    [Fact]
    public void BytesTheEngineCannotOpenGiveNoCopy() =>
        Assert.Null(DisplayCopy.Create([1, 2, 3], null, []));
}
