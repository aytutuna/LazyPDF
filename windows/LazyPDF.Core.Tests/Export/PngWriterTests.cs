using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PngWriterTests
{
    private static PdfRgbaImage Gradient(int w, int h, byte alpha)
    {
        var rgba = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int o = (y * w + x) * 4;
                rgba[o] = (byte)(x * 7 + y);
                rgba[o + 1] = (byte)(y * 11);
                rgba[o + 2] = (byte)((x ^ y) * 13);
                rgba[o + 3] = alpha == 0 ? (byte)(x * 255 / Math.Max(1, w - 1)) : alpha;
            }
        }
        return new PdfRgbaImage(w, h, rgba);
    }

    [Theory]
    [InlineData(1, 1)]
    [InlineData(7, 5)]
    [InlineData(64, 33)]
    public void OpaqueColourRoundTrips(int w, int h)
    {
        var image = Gradient(w, h, 255);
        var (dw, dh, rgba) = ExportKit.PngDecode(PngWriter.Encode(image));
        Assert.Equal((w, h), (dw, dh));
        Assert.Equal(image.Rgba, rgba);
    }

    [Fact]
    public void TransparencyRoundTrips()
    {
        var image = Gradient(40, 20, 0);
        var png = PngWriter.Encode(image);
        Assert.Equal(6, png[25]);
        Assert.Equal(image.Rgba, ExportKit.PngDecode(png).Rgba);
    }

    [Fact]
    public void GrayPixelsAreWrittenAsOneChannel()
    {
        var rgba = new byte[16 * 16 * 4];
        for (int i = 0; i < 256; i++) (rgba[4 * i], rgba[4 * i + 1], rgba[4 * i + 2], rgba[4 * i + 3]) = ((byte)i, (byte)i, (byte)i, 255);
        var png = PngWriter.Encode(new PdfRgbaImage(16, 16, rgba));
        Assert.Equal(0, png[25]);
        Assert.Equal(rgba, ExportKit.PngDecode(png).Rgba);
    }

    [Fact]
    public void SmoothAreasCompressWell()
    {
        var flat = new byte[200 * 200 * 4];
        Array.Fill(flat, (byte)200);
        Assert.True(PngWriter.Encode(new PdfRgbaImage(200, 200, flat)).Length < 600);
    }

    [Theory]
    [InlineData(0, 1, 0)]
    [InlineData(2, 2, 7)]
    [InlineData(2, 2, 15)]
    public void DataThatDoesNotFitIsRefused(int w, int h, int length)
    {
        Assert.Throws<ArgumentException>(() => PngWriter.Encode(new PdfRgbaImage(w, h, new byte[length])));
    }
}
