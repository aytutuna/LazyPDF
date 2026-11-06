using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeImageTests
{
    private static string Dictionary(int w, int h, string space, int bpc = 8, string extra = "") =>
        $"/Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace {space} /BitsPerComponent {bpc} /Filter /FlateDecode {extra}";

    private static OptimizeOptions Downsample(int dpi, int above, int quality = 75) =>
        OptimizeKit.Off with { ImageDpi = dpi, ImageDpiAbove = above, JpegQuality = quality };

    private static byte[] Place(string dictionary, byte[] samples, string size = "100", Action<TestPdf>? more = null) =>
        OptimizeKit.Build($"q {size} 0 0 {size} 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
        {
            pdf.Stream(5, dictionary, TestPdf.Deflate(samples));
            more?.Invoke(pdf);
        });

    private static PdfStream Run(byte[] file, OptimizeOptions options, out PdfDocument after, IImageCodec? codec = null, string name = "Im0")
    {
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document, codec).Run(options);
        after = PdfDocument.Open(result.Bytes);
        return OptimizeKit.Image(after, name);
    }

    [Fact]
    public void RgbImageIsAveragedDownToTheRequestedResolution()
    {
        var samples = OptimizeKit.Gradient(200, 200, 3);
        var image = Run(Place(Dictionary(200, 200, "/DeviceRGB"), samples), Downsample(72, 100), out var after);
        Assert.Equal(100, after.Integer(image.Dictionary, "Width"));
        Assert.Equal(100, after.Integer(image.Dictionary, "Height"));
        var data = after.Data(image);
        Assert.Equal(100 * 100 * 3, data.Length);
        for (int c = 0; c < 3; c++)
        {
            int expected = (samples[c] + samples[3 + c] + samples[200 * 3 + c] + samples[200 * 3 + 3 + c] + 2) / 4;
            Assert.Equal(expected, data[c]);
        }
    }

    [Fact]
    public void ImageBelowTheThresholdIsLeft()
    {
        var samples = OptimizeKit.Gradient(100, 100, 3);
        var image = Run(Place(Dictionary(100, 100, "/DeviceRGB"), samples), Downsample(72, 150), out var after);
        Assert.Equal(100, after.Integer(image.Dictionary, "Width"));
    }

    [Fact]
    public void SoftMaskAndDecodeSurviveDownsampling()
    {
        var samples = OptimizeKit.Gradient(200, 200, 3);
        var mask = OptimizeKit.Gradient(200, 200, 1);
        byte[] file = Place(Dictionary(200, 200, "/DeviceRGB", extra: "/Decode [1 0 1 0 1 0] /SMask 6 0 R"), samples, more: pdf =>
            pdf.Stream(6, Dictionary(200, 200, "/DeviceGray"), TestPdf.Deflate(mask)));
        var image = Run(file, Downsample(72, 100), out var after);
        Assert.Equal(100, after.Integer(image.Dictionary, "Width"));
        Assert.Equal(6, ((PdfArray)after.Resolve(image.Dictionary["Decode"])!).Items.Count);
        var soft = after.Stream(image.Dictionary, "SMask");
        Assert.NotNull(soft);
        Assert.Equal(100, after.Integer(soft!.Dictionary, "Width"));
        Assert.Equal(100 * 100, after.Data(soft).Length);
    }

    [Fact]
    public void ImageIsSizedForItsLargestUseInsideForms()
    {
        var samples = OptimizeKit.Gradient(200, 200, 3);
        byte[] file = OptimizeKit.Build("q 0.5 0 0 0.5 0 0 cm /Fm0 Do Q q 1 0 0 1 100 100 cm /Fm0 Do Q", "/XObject <</Fm0 6 0 R>>", pdf =>
        {
            pdf.Stream(5, Dictionary(200, 200, "/DeviceRGB"), TestPdf.Deflate(samples));
            pdf.Stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <</XObject <</Im0 5 0 R>>>>", "q 100 0 0 100 0 0 cm /Im0 Do Q");
        });
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(Downsample(72, 100));
        using var after = PdfDocument.Open(result.Bytes);
        var image = (PdfStream)after.Resolve(after.Dict(after.Dict(((PdfStream)after.Resolve(after.Dict(after.Pages[0].Resources, "XObject")!["Fm0"])!).Dictionary, "Resources"), "XObject")!["Im0"])!;
        // 288 dpi on the small copy and 144 on the big one: 100 pixels give the big one the 72 dpi asked for.
        Assert.Equal(100, after.Integer(image.Dictionary, "Width"));
    }

    [Fact]
    public void ImageUsedAtFullSizeSomewhereIsLeft()
    {
        var samples = OptimizeKit.Gradient(200, 200, 3);
        byte[] file = OptimizeKit.Build("q 50 0 0 50 0 0 cm /Im0 Do Q q 200 0 0 200 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf =>
            pdf.Stream(5, Dictionary(200, 200, "/DeviceRGB"), TestPdf.Deflate(samples)));
        var image = Run(file, Downsample(72, 100), out var after);
        // 288 dpi at the small use but only 72 at the big one, which needs every pixel it has.
        Assert.Equal(200, after.Integer(image.Dictionary, "Width"));
    }

    [Fact]
    public void CmykKeepsFourComponents()
    {
        var samples = OptimizeKit.Gradient(200, 200, 4);
        var image = Run(Place(Dictionary(200, 200, "/DeviceCMYK"), samples), Downsample(72, 100), out var after);
        Assert.Equal("DeviceCMYK", after.Name(image.Dictionary, "ColorSpace"));
        Assert.Equal(100 * 100 * 4, after.Data(image).Length);
    }

    [Fact]
    public void IndexedImageBecomesRgb()
    {
        var palette = new byte[256 * 3];
        for (int i = 0; i < 256; i++) (palette[3 * i], palette[3 * i + 1], palette[3 * i + 2]) = ((byte)i, (byte)(255 - i), 40);
        var indices = new byte[200 * 200];
        for (int i = 0; i < indices.Length; i++) indices[i] = (byte)(i % 200 * 255 / 200);
        string space = $"[/Indexed /DeviceRGB 255 <{Convert.ToHexString(palette)}>]";
        var image = Run(Place(Dictionary(200, 200, space), indices), Downsample(72, 100), out var after);
        Assert.Equal("DeviceRGB", after.Name(image.Dictionary, "ColorSpace"));
        Assert.Equal(100 * 100 * 3, after.Data(image).Length);
    }

    [Fact]
    public void BlackAndWhitePictureBecomesOneBit()
    {
        const int w = 40, h = 30;
        var gray = new byte[w * h];
        var rng = new Random(3);
        for (int i = 0; i < gray.Length; i++) gray[i] = (byte)((i / 5 + i / w) % 2 == 0 ? rng.Next(0, 4) : rng.Next(252, 256));
        var options = OptimizeKit.Off with { BilevelTolerance = 8 };
        var image = Run(Place(Dictionary(w, h, "/DeviceGray"), gray), options, out var after);
        Assert.Equal(1, after.Integer(image.Dictionary, "BitsPerComponent"));
        var bits = after.Data(image);
        Assert.Equal(5 * h, bits.Length);
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                bool white = (bits[y * 5 + x / 8] & (0x80 >> x % 8)) != 0;
                Assert.Equal(gray[y * w + x] > 128, white);
            }
        }
    }

    [Fact]
    public void PictureWithMidTonesStaysEightBit()
    {
        var gray = OptimizeKit.Gradient(40, 30, 1);
        var image = Run(Place(Dictionary(40, 30, "/DeviceGray"), gray), OptimizeKit.Off with { BilevelTolerance = 8 }, out var after);
        Assert.Equal(8, after.Integer(image.Dictionary, "BitsPerComponent"));
    }

    [Fact]
    public void JpegIsDecodedShrunkAndWrittenAgain()
    {
        string dictionary = "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode";
        byte[] file = OptimizeKit.Build("q 72 0 0 72 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf => pdf.Stream(5, dictionary, OptimizeKit.TinyJpeg));
        var codec = new OptimizeFakeCodec();
        var image = Run(file, Downsample(8, 10, quality: 60), out var after, codec);
        Assert.Equal("DCTDecode", after.Name(image.Dictionary, "Filter"));
        Assert.Equal(8, after.Integer(image.Dictionary, "Width"));
        Assert.Equal(60, codec.LastQuality);
        Assert.True(after.RawData(image).Length < OptimizeKit.TinyJpeg.Length);
        Assert.Equal(8, codec.LastEncoded!.Width);
    }

    [Fact]
    public void JpegWithoutACodecIsLeftAndSaysSo()
    {
        string dictionary = "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode";
        byte[] file = OptimizeKit.Build("q 72 0 0 72 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf => pdf.Stream(5, dictionary, OptimizeKit.TinyJpeg));
        using var document = PdfDocument.Open(file);
        var result = new PdfOptimizer(document).Run(Downsample(8, 10));
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal(16, after.Integer(OptimizeKit.Image(after).Dictionary, "Width"));
        Assert.Contains(OptimizeText.NeedsCodec, result.Notes);
    }

    [Fact]
    public void JpegWithADecodeArrayIsLeft()
    {
        string dictionary = "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Decode [1 0 1 0 1 0]";
        byte[] file = OptimizeKit.Build("q 72 0 0 72 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf => pdf.Stream(5, dictionary, OptimizeKit.TinyJpeg));
        var codec = new OptimizeFakeCodec();
        var image = Run(file, Downsample(8, 10), out var after, codec);
        Assert.Equal(16, after.Integer(image.Dictionary, "Width"));
        Assert.Equal(0, codec.Decodes);
    }

    [Fact]
    public void JpegWhoseHeaderReadsZeroHeightIsLeft()
    {
        string dictionary = "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode";
        var jpeg = (byte[])OptimizeKit.TinyJpeg.Clone();
        int at = jpeg.AsSpan().IndexOf(new byte[] { 0xFF, 0xC0 });
        jpeg[at + 5] = 0;
        jpeg[at + 6] = 0;
        byte[] file = OptimizeKit.Build("q 72 0 0 72 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", pdf => pdf.Stream(5, dictionary, jpeg));
        var image = Run(file, Downsample(8, 10), out var after, new OptimizeFakeCodec());
        Assert.Equal(16, after.Integer(image.Dictionary, "Width"));
        Assert.Equal(jpeg, after.RawData(image));
    }

    [Fact]
    public void ImagePlacedWithAMatrixThatOverflowsIsLeft()
    {
        string big = "1" + new string('0', 300);
        string content = $"q {big} 0 0 {big} 0 0 cm {big} 0 0 {big} 0 0 cm 0 0 0 0 0 0 cm /Im0 Do Q";
        var samples = OptimizeKit.Gradient(200, 200, 3);
        byte[] file = OptimizeKit.Build(content, "/XObject <</Im0 5 0 R>>", pdf => pdf.Stream(5, Dictionary(200, 200, "/DeviceRGB"), TestPdf.Deflate(samples)));
        var image = Run(file, Downsample(72, 100), out var after);
        Assert.Equal(200, after.Integer(image.Dictionary, "Width"));
    }

    [Fact]
    public void ImageOnlyReachedByAType3GlyphIsLeft()
    {
        var samples = OptimizeKit.Gradient(200, 200, 3);
        byte[] file = OptimizeKit.Build("q 100 0 0 100 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", pdf =>
        {
            pdf.Stream(5, Dictionary(200, 200, "/DeviceRGB"), TestPdf.Deflate(samples));
            pdf.Obj(6, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] /CharProcs <</a 7 0 R>> /Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [1] /Resources <</XObject <</Im0 5 0 R>>>>>>");
            pdf.Stream(7, "", "1 0 d0 q 1 0 0 1 0 0 cm /Im0 Do Q");
        });
        var image = Run(file, Downsample(72, 100), out var after);
        Assert.Equal(200, after.Integer(image.Dictionary, "Width"));
    }
}
