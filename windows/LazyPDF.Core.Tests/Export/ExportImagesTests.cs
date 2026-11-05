using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Hands back the same gray pixels for every coded stream it is asked to read.</summary>
internal sealed class ExportPixelCodec(int width, params byte[] gray) : IImageCodec
{
    public PdfRgbaImage? Decode(byte[] data, string codec)
    {
        var rgba = new byte[gray.Length * 4];
        for (int i = 0; i < gray.Length; i++) (rgba[4 * i], rgba[4 * i + 1], rgba[4 * i + 2], rgba[4 * i + 3]) = (gray[i], gray[i], gray[i], 255);
        return new PdfRgbaImage(width, gray.Length / width, rgba);
    }

    public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file) => null;

    public byte[] EncodeJpeg(PdfRgbaImage image, int quality) => throw new NotSupportedException();
}

public class ExportImagesTests
{
    private const string Image = "/Type /XObject /Subtype /Image";
    private const string Ink = "[/Separation /Black /DeviceCMYK <</FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 0 0 1] /N 1>>]";

    private static PdfDocument Open(string content, Action<TestPdf> objects, string pageEntries = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R {pageEntries} /Resources <</XObject <</Im 10 0 R>>>> /Contents 30 0 R>>");
        pdf.Stream(30, "", content);
        objects(pdf);
        return PdfDocument.Open(pdf.Finish());
    }

    private static ExportImage Extract(string entries, byte[] data, IImageCodec? codec, Action<TestPdf>? more = null)
    {
        var document = Open("q 10 0 0 10 0 0 cm /Im Do Q", pdf =>
        {
            pdf.Stream(10, $"{Image} {entries}", data);
            more?.Invoke(pdf);
        });
        return Assert.Single(ImageExtractor.Extract(document, codec: codec)).Image;
    }

    private static IEnumerable<byte> Alpha(ExportImage image) => ExportKit.PngDecode(image.Data).Rgba.Where((_, i) => i % 4 == 3);

    [Fact]
    public void APictureOverTheSizeLimitIsLeftOutAndCounted()
    {
        var document = Open("q 10 0 0 10 0 0 cm /Im Do Q", pdf => pdf.Stream(10, $"{Image} /Width 10000 /Height 10000 /ColorSpace /DeviceGray /BitsPerComponent 8", [1]));

        var model = ExportLayout.Analyze(document);

        Assert.Equal(1, model.PicturesLeftOut);
        Assert.Empty(model.Pages[0].Pictures);
        Assert.Equal("1 picture was left out because the file is too large.", ExportText.PicturesLeftOut(1));
    }

    [Fact]
    public void APictureThatWasKeptIsNotCounted()
    {
        var document = Open("q 10 0 0 10 0 0 cm /Im Do Q", pdf => pdf.Stream(10, $"{Image} /Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 255]));

        var model = ExportLayout.Analyze(document);

        Assert.Equal(0, model.PicturesLeftOut);
        Assert.Single(model.Pages[0].Pictures);
    }

    [Fact]
    public void ADecodeArrayOnAJpegIsHonoured()
    {
        var png = Extract("/Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Decode [1 0]", [1], new ExportPixelCodec(2, 0, 200));
        Assert.Equal([255, 255, 255, 255, 55, 55, 55, 255], ExportKit.PngDecode(png.Data).Rgba);
    }

    [Fact]
    public void AStencilMaskOnAJpegBecomesAlpha()
    {
        var png = Extract("/Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Mask 11 0 R", [1], new ExportPixelCodec(2, 90, 90),
            pdf => pdf.Stream(11, $"{Image} /Width 2 /Height 1 /ImageMask true /BitsPerComponent 1", [0b0100_0000]));
        Assert.Equal([255, 0], Alpha(png));
    }

    [Fact]
    public void AnImageMaskKeepsItsDecodePolarityWhateverTheFilter()
    {
        var png = Extract("/Width 2 /Height 1 /ImageMask true /BitsPerComponent 1 /Filter /JBIG2Decode /Decode [1 0]", [1], new ExportPixelCodec(2, 0, 255));
        Assert.Equal([0, 255], Alpha(png));
    }

    [Fact]
    public void AColourKeyMaskOnAJpegMakesTheKeyedColourTransparent()
    {
        var png = Extract("/Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Mask [0 10]", [1], new ExportPixelCodec(2, 5, 200));
        Assert.Equal([0, 255], Alpha(png));
    }

    [Fact]
    public void ASoftMaskStoredAsJpegIsReadThroughTheCodec()
    {
        const string entries = "/Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /SMask 11 0 R";
        void Mask(TestPdf pdf) => pdf.Stream(11, $"{Image} /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", [1]);
        var with = Extract(entries, TestPdf.Deflate([9, 8, 7]), new ExportPixelCodec(1, 128), Mask);
        Assert.Equal([9, 8, 7, 128], ExportKit.PngDecode(with.Data).Rgba);
        var without = Extract(entries, TestPdf.Deflate([9, 8, 7]), null, Mask);
        Assert.Equal([9, 8, 7, 255], ExportKit.PngDecode(without.Data).Rgba);
    }

    [Fact]
    public void AJpegWithAJpxSoftMaskKeepsItsColoursAndTakesTheAlpha()
    {
        var png = Extract("/Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /SMask 11 0 R", [1], new ExportPixelCodec(1, 64),
            pdf => pdf.Stream(11, $"{Image} /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /JPXDecode", [1]));
        Assert.Equal([64, 64, 64, 64], ExportKit.PngDecode(png.Data).Rgba);
    }

    [Fact]
    public void ASeparationJpegIsInkedNotShownAsGray()
    {
        var png = Extract($"/Width 1 /Height 1 /ColorSpace {Ink} /BitsPerComponent 8 /Filter /DCTDecode", [1], new ExportPixelCodec(1, 255));
        Assert.False(png.IsJpeg);
        Assert.True(ExportKit.PngDecode(png.Data).Rgba[0] < 80);
    }

    [Fact]
    public void ASeparationJpegWithoutACodecStaysAJpeg()
    {
        Assert.True(Extract($"/Width 1 /Height 1 /ColorSpace {Ink} /BitsPerComponent 8 /Filter /DCTDecode", [1], null).IsJpeg);
    }

    [Fact]
    public void AnInlineImagePaintedAgainIsDecodedOnce()
    {
        string inline = "q 40 0 0 40 0 0 cm BI /W 2 /H 2 /CS /RGB /BPC 8 ID " + Encoding.Latin1.GetString([255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9]) + " EI Q\n";
        var found = ImageExtractor.Extract(Open(string.Concat(Enumerable.Repeat(inline, 5)), _ => { }));
        Assert.Equal(5, found.Count);
        Assert.All(found, f => Assert.Same(found[0].Image, f.Image));
    }

    private static PdfDocument Rotated(string pageEntries, string cm) => Open($"q {cm} cm /Im Do Q", pdf =>
        pdf.Stream(10, $"{Image} /Width 2 /Height 3 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.Deflate([10, 20, 30, 40, 50, 60])), pageEntries);

    private static (int Width, int Height, byte[] Gray) OnlyPicture(PdfDocument document)
    {
        var picture = Assert.Single(ExportLayout.Analyze(document).Pages[0].Pictures);
        var (w, h, rgba) = ExportKit.PngDecode(picture.Image.Data);
        Assert.Equal(picture.Bounds.Width > picture.Bounds.Height, w > h);
        return (w, h, [.. rgba.Where((_, i) => i % 4 == 0)]);
    }

    [Fact]
    public void APictureOnARotatedPageIsTurnedToMatchItsBox()
    {
        var (w, h, gray) = OnlyPicture(Rotated("/Rotate 90", "200 0 0 300 100 100"));
        Assert.Equal((3, 2), (w, h));
        Assert.Equal([50, 30, 10, 60, 40, 20], gray);
    }

    [Fact]
    public void AMirroredPictureIsMirroredInTheExport()
    {
        var (w, h, gray) = OnlyPicture(Rotated("", "-200 0 0 300 300 100"));
        Assert.Equal((2, 3), (w, h));
        Assert.Equal([20, 10, 40, 30, 60, 50], gray);
    }

    [Fact]
    public void AnUprightPictureIsLeftAlone()
    {
        Assert.Equal([10, 20, 30, 40, 50, 60], OnlyPicture(Rotated("", "200 0 0 300 100 100")).Gray);
    }

    [Fact]
    public void ANameFromTheFileCannotLeaveTheOutputFolder()
    {
        var image = new ExportImage([1], true, 1, 1);
        string file = new ExportedImage(0, @"../..\a:b", image).FileName;
        Assert.DoesNotContain(file, c => c is '/' or '\\' or ':');
        Assert.Equal(file, Path.GetFileName(file));
    }
}
