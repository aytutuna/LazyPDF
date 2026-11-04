using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ImageExtractorTests
{
    private const string Fonts = "/XObject <</Jpg 10 0 R /Alpha 11 0 R /Jpx 13 0 R /Jbig 14 0 R /Broken 15 0 R /Masked 16 0 R /Frm 17 0 R /Huge 18 0 R>>";

    private static readonly byte[] Rgb2x2 = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0];

    private static PdfDocument Open(string content)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Resources <<{Fonts}>> /Contents 30 0 R>>");
        pdf.Obj(4, $"<</Type /Page /Parent 2 0 R /Resources <<{Fonts}>> /Contents 31 0 R>>");
        pdf.Stream(10, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", ExportKit.Jpeg);
        pdf.Stream(11, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /SMask 12 0 R", TestPdf.Deflate(Rgb2x2));
        pdf.Stream(12, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.Deflate([0, 85, 170, 255]));
        pdf.Stream(13, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode", [1, 2, 3]);
        pdf.Stream(14, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode", [1, 2, 3]);
        pdf.Stream(15, "/Type /XObject /Subtype /Image /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8", Rgb2x2);
        pdf.Stream(16, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /SMask 12 0 R", ExportKit.Jpeg);
        pdf.Stream(17, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <<" + Fonts + ">>", "q 50 0 0 50 0 0 cm /Alpha Do Q");
        pdf.Stream(18, "/Type /XObject /Subtype /Image /Width 100000 /Height 100000 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.Deflate([0, 0]));
        pdf.Stream(30, "", content);
        pdf.Stream(31, "", "q 20 0 0 20 0 0 cm /Alpha Do Q");
        return PdfDocument.Open(pdf.Finish());
    }

    [Fact]
    public void AJpegIsKeptAsItsBytes()
    {
        var found = ImageExtractor.Extract(Open("q 80 0 0 60 10 10 cm /Jpg Do Q"), [0]);
        var image = Assert.Single(found);
        Assert.Equal((0, "Jpg", "page1_Jpg.jpg"), (image.PageIndex, image.Name, image.FileName));
        Assert.True(image.Image.IsJpeg);
        Assert.Equal(ExportKit.Jpeg, image.Image.Data);
        Assert.Equal((8, 6), (image.Image.Width, image.Image.Height));
    }

    [Fact]
    public void OtherImagesBecomePngWithTheMaskAsAlpha()
    {
        var image = Assert.Single(ImageExtractor.Extract(Open("q 80 0 0 60 10 10 cm /Alpha Do Q"), [0])).Image;
        Assert.False(image.IsJpeg);
        var (w, h, rgba) = ExportKit.PngDecode(image.Data);
        Assert.Equal((2, 2), (w, h));
        Assert.Equal([255, 0, 0, 0], rgba[..4]);
        Assert.Equal([0, 255, 0, 85], rgba[4..8]);
        Assert.Equal([0, 0, 255, 170], rgba[8..12]);
        Assert.Equal([255, 255, 0, 255], rgba[12..16]);
    }

    [Fact]
    public void AnImagePaintedTwiceIsListedOnceAndOneInAFormToo()
    {
        var found = ImageExtractor.Extract(Open("q 80 0 0 60 10 10 cm /Alpha Do Q q 80 0 0 60 10 10 cm /Alpha Do Q q /Frm Do Q"), [0]);
        Assert.Equal(["Alpha"], found.Select(f => f.Name));
    }

    [Fact]
    public void EveryPageIsWalkedAndKeepsItsNumber()
    {
        var found = ImageExtractor.Extract(Open("q 80 0 0 60 10 10 cm /Jpg Do Q"));
        Assert.Equal([(0, "Jpg"), (1, "Alpha")], found.Select(f => (f.PageIndex, f.Name)));
    }

    [Fact]
    public void WithoutACodecJpeg2000AndJbig2AreLeftOutAndABrokenImageToo()
    {
        var found = ImageExtractor.Extract(Open("q /Jpx Do /Jbig Do /Broken Do /Jpg Do Q"), [0]);
        Assert.Equal(["Jpg"], found.Select(f => f.Name));
    }

    [Fact]
    public void ACodecDecodesThoseAndAJpegWithAMaskGoesThroughIt()
    {
        var codec = new ExportFakeCodec();
        var found = ImageExtractor.Extract(Open("q /Jpx Do /Jbig Do /Masked Do Q"), [0], codec);
        Assert.Equal(["Jpx", "Jbig", "Masked"], found.Select(f => f.Name));
        Assert.All(found, f => Assert.False(f.Image.IsJpeg));
        Assert.Equal(["JPXDecode", "JBIG2Decode", "DCTDecode"], codec.Decoded);
        var masked = ExportKit.PngDecode(found[2].Image.Data);
        Assert.Equal([0, 85, 170, 255], masked.Rgba.Where((_, i) => i % 4 == 3).Take(4));
    }

    [Fact]
    public void AJpegWithAMaskStaysAJpegWithoutACodec()
    {
        var image = Assert.Single(ImageExtractor.Extract(Open("q /Masked Do Q"), [0])).Image;
        Assert.True(image.IsJpeg);
    }

    [Fact]
    public void InlineImagesGetNamesOfTheirOwn()
    {
        var content = "q 40 0 0 40 0 0 cm BI /W 2 /H 2 /CS /RGB /BPC 8 ID " + System.Text.Encoding.Latin1.GetString(Rgb2x2) + " EI Q";
        var image = Assert.Single(ImageExtractor.Extract(Open(content), [0]));
        Assert.Equal("inline1", image.Name);
        Assert.Equal([255, 0, 0, 255], ExportKit.PngDecode(image.Image.Data).Rgba[..4]);
    }

    [Fact]
    public void AnImageTooBigToDecodeIsLeftOut()
    {
        var found = ImageExtractor.Extract(Open("q /Huge Do /Jpg Do Q"), [0]);
        Assert.Equal(["Jpg"], found.Select(f => f.Name));
    }

    [Fact]
    public void ABadPageIndexIsRefusedAndCancellationHonoured()
    {
        var document = Open("");
        Assert.Throws<ArgumentOutOfRangeException>(() => ImageExtractor.Extract(document, [2]));
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => ImageExtractor.Extract(document, cancel: cts.Token));
    }

    [Fact]
    public void ADocumentWithoutImagesGivesNone()
    {
        Assert.Empty(ImageExtractor.Extract(ExportKit.Open("BT /F1 12 Tf 72 700 Td (text) Tj ET")));
    }
}
