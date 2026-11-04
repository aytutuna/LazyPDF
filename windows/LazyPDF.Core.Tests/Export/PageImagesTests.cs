using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageImagesTests
{
    [Fact]
    public void ThePageComesBackAsAPngOfTheRenderedPixels()
    {
        var renderer = new ExportFakeRenderer(30, 20);
        var png = PageImages.Png(renderer, 1, 150)!;
        var (w, h, rgba) = ExportKit.PngDecode(png);
        Assert.Equal((30, 20), (w, h));
        Assert.Equal(renderer.Render(1, 150)!.Rgba, rgba);
    }

    [Fact]
    public void TransparencyIsKeptInThePng()
    {
        var png = PageImages.Png(new ExportFakeRenderer(8, 8, alpha: 100), 0, 72)!;
        Assert.Equal(100, ExportKit.PngDecode(png).Rgba[3]);
    }

    [Fact]
    public void APageTheRendererCannotDrawGivesNull()
    {
        Assert.Null(PageImages.Png(new ExportFakeRenderer(8, 8), 5, 72));
        Assert.Null(PageImages.Jpeg(new ExportFakeRenderer(8, 8), new ExportFakeCodec(), 5, 72));
    }

    [Fact]
    public void TheJpegComesFromTheCodecAndTransparencyIsFlattenedOnWhite()
    {
        var renderer = new ExportFakeRenderer(8, 8, alpha: 0);
        var jpeg = PageImages.Jpeg(renderer, new ExportFakeCodec(), 0, 72, 60)!;
        Assert.Equal(new byte[] { 0xFF, 0xD8, 60, 1, 0xFF, 0xD9 }, jpeg);
    }

    [Fact]
    public void FlatteningLeavesTheRenderersPixelsAlone()
    {
        var shared = new PdfRgbaImage(1, 1, [10, 20, 30, 0]);
        var renderer = new Reuse(shared);
        var codec = new Capture();
        PageImages.Jpeg(renderer, codec, 0, 72);
        Assert.Equal([255, 255, 255, 255], codec.Seen!.Rgba);
        Assert.Equal([10, 20, 30, 0], shared.Rgba);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(1201)]
    [InlineData(double.NaN)]
    public void ADpiOutOfRangeIsRefused(double dpi)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => PageImages.Png(new ExportFakeRenderer(8, 8), 0, dpi));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageImages.Jpeg(new ExportFakeRenderer(8, 8), new ExportFakeCodec(), 0, dpi));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(101)]
    public void AQualityOutOfRangeIsRefused(int quality)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => PageImages.Jpeg(new ExportFakeRenderer(8, 8), new ExportFakeCodec(), 0, 72, quality));
    }

    private sealed class Reuse(PdfRgbaImage image) : IPageRenderer
    {
        public PdfRgbaImage? Render(int pageIndex, double dpi) => image;
    }

    private sealed class Capture : IImageCodec
    {
        public PdfRgbaImage? Seen { get; private set; }
        public PdfRgbaImage? Decode(byte[] data, string codec) => null;
        public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file) => null;

        public byte[] EncodeJpeg(PdfRgbaImage image, int quality)
        {
            Seen = image;
            return [];
        }
    }
}
