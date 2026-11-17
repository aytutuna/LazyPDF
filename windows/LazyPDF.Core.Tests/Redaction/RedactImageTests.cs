using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactImageTests
{
    private const string Place = "q 160 0 0 160 100 100 cm /Im1 Do Q";

    // Pixel (x, y) holds 1 + y * 8 + x, never zero, so a zeroed pixel is a removed one.
    private static byte[] Gradient() => [.. Enumerable.Range(0, 64).Select(i => (byte)(i + 1))];

    private static PdfDocument WithImage(string entries, byte[] data, string content = Place, Action<TestPdf>? more = null) =>
        RedactionKit.Page(content, "/XObject <</Im1 6 0 R>>", pdf =>
        {
            pdf.Stream(6, $"/Type /XObject /Subtype /Image /Width 8 /Height 8 {entries}", data);
            more?.Invoke(pdf);
        });

    private static byte[] Samples(PdfDocument document, int page = 0) =>
        document.Data(RedactionKit.Images(document, page).Single().Stream!);

    // The top left 2 by 2 pixels: the image covers 100..260 on both axes, a pixel is 20 points.
    private static RedactionMark TopLeft(int page = 0) => RedactionMark.FromRect(page, new PdfRect(100, 220, 140, 260));

    private static IEnumerable<PdfStream> ImageStreams(PdfDocument document) =>
        document.ObjectNumbers.Select(document.Get).OfType<PdfStream>().Where(s => document.Name(s.Dictionary, "Subtype") == "Image");

    [Fact]
    public void PixelsUnderTheMarkAreZeroInTheSamplesAndTheOthersStay()
    {
        using var document = WithImage("/ColorSpace /DeviceGray /BitsPerComponent 8", Gradient());
        var result = new PdfRedactor(document).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var expected = Gradient();
        foreach (int i in new[] { 0, 1, 8, 9 }) expected[i] = 0;
        Assert.Equal(expected, Samples(output));
        Assert.Equal(1, result.Report.Images);
        Assert.Equal(0, result.Report.Pages.Single().WholeImages);
    }

    [Fact]
    public void TheCoveredPixelsAreNotInTheFileAnywhere()
    {
        var data = Gradient();
        using var document = WithImage("/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.Deflate(data));
        var result = new PdfRedactor(document).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var only = Assert.Single(ImageStreams(output));
        Assert.NotEqual(data, output.Data(only));
        Assert.Equal(data[2..8], output.Data(only)[2..8]);
    }

    [Fact]
    public void FourBitSamplesAreClearedByTheBit()
    {
        var data = Enumerable.Repeat((byte)0xFF, 32).ToArray();
        using var document = WithImage("/ColorSpace /DeviceGray /BitsPerComponent 4", data);
        var result = new PdfRedactor(document).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var samples = Samples(output);
        Assert.Equal(0, samples[0]);
        Assert.Equal(0, samples[4]);
        Assert.Equal(0xFF, samples[1]);
        Assert.Equal(0xFF, samples[8]);
    }

    [Fact]
    public void ImageMaskBitsAreCleared()
    {
        var data = Enumerable.Repeat((byte)0xFF, 8).ToArray();
        using var document = WithImage("/ImageMask true /BitsPerComponent 1", data);
        var result = new PdfRedactor(document).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var samples = Samples(output);
        Assert.Equal(0x3F, samples[0]);
        Assert.Equal(0x3F, samples[1]);
        Assert.Equal(0xFF, samples[2]);
    }

    [Fact]
    public void SoftMaskIsCutToo()
    {
        using var document = WithImage("/ColorSpace /DeviceGray /BitsPerComponent 8 /SMask 7 0 R", Gradient(),
            more: pdf => pdf.Stream(7, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8", Gradient()));
        var result = new PdfRedactor(document).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var image = RedactionKit.Images(output).Single().Stream!;
        var mask = output.Data(output.Stream(image.Dictionary, "SMask")!);
        Assert.Equal(0, mask[0]);
        Assert.Equal(0, mask[9]);
        Assert.Equal(3, mask[2]);
        Assert.Equal(2, ImageStreams(output).Count());
    }

    [Theory]
    [InlineData("JPXDecode")]
    [InlineData("DCTDecode")]
    public void ACodedSoftMaskIsWrittenBackAsPlainGrayWithItsMatte(string filter)
    {
        using var document = WithImage("/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode /SMask 7 0 R", [1, 2, 3],
            more: pdf => pdf.Stream(7, $"/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /{filter} /Matte [0 0 0]", [1, 2, 3]));
        var result = new PdfRedactor(document, images: new FakeCodec(Eight(60, 60, 60, 255))).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var image = RedactionKit.Images(output).Single().Stream!;
        var mask = output.Stream(image.Dictionary, "SMask")!;

        Assert.Equal("DeviceGray", output.Name(mask.Dictionary, "ColorSpace"));
        Assert.Equal(8, output.Integer(mask.Dictionary, "BitsPerComponent"));
        Assert.False(mask.Dictionary.ContainsKey("SMask"));
        Assert.NotNull(mask.Dictionary["Matte"]);
        Assert.Equal([0, 0, 60], output.Data(mask)[..3].Select(b => (int)b));
        Assert.Equal(64, output.Data(mask).Length);
    }

    [Theory]
    [InlineData("DCTDecode", true)]
    [InlineData("JPXDecode", false)]
    public void ACodedSoftMaskKeepsOnlyWhatAPlainGrayMaskHas(string filter, bool decode)
    {
        using var document = WithImage("/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode /SMask 7 0 R", [1, 2, 3],
            more: pdf =>
            {
                pdf.Stream(7, $"/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /{filter} /Decode [1 0] /SMask 8 0 R /Mask 9 0 R /SMaskInData 1", [1, 2, 3]);
                pdf.Stream(8, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8", Gradient());
                pdf.Stream(9, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ImageMask true /BitsPerComponent 1", new byte[8]);
            });
        var result = new PdfRedactor(document, images: new FakeCodec(Eight(60, 60, 60, 255))).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var image = RedactionKit.Images(output).Single().Stream!;
        var mask = output.Stream(image.Dictionary, "SMask")!;

        Assert.Equal(decode, mask.Dictionary.ContainsKey("Decode"));
        foreach (string key in new[] { "SMask", "Mask", "SMaskInData" }) Assert.False(mask.Dictionary.ContainsKey(key), key);
        Assert.Equal(2, ImageStreams(output).Count());
    }

    [Theory]
    [InlineData("/DeviceRGB", "[0 0 0]", "[0 0 0]")]
    [InlineData("/DeviceRGB", "[0]", null)]
    [InlineData("/DeviceGray", "[0.5]", "[0.5 0.5 0.5]")]
    [InlineData("/DeviceCMYK", "[0 0 0 0]", null)]
    public void TheMatteOfASoftMaskFollowsTheColourSpaceTheImageIsWrittenIn(string space, string matte, string? expected)
    {
        using var document = WithImage($"/ColorSpace {space} /BitsPerComponent 8 /Filter /JPXDecode /SMask 7 0 R", [1, 2, 3],
            more: pdf => pdf.Stream(7, $"/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Matte {matte}", [1, 2, 3]));
        var result = new PdfRedactor(document, images: new FakeCodec(Eight(60, 60, 60, 255))).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var image = RedactionKit.Images(output).Single().Stream!;
        var written = output.Stream(image.Dictionary, "SMask")!.Dictionary["Matte"];

        Assert.Equal(expected, written?.ToString());
    }

    // A JPX picture usually has no /ColorSpace, so its component count is not known from the dictionary.
    [Theory]
    [InlineData("[0.5]", "[0.5 0.5 0.5]")]
    [InlineData("[0 0 0]", "[0 0 0]")]
    [InlineData("[0 0]", null)]
    [InlineData("[0 0 0 0]", null)]
    public void WithNoColourSpaceTheMatteIsRepeatedOrKeptByItsLength(string matte, string? expected)
    {
        using var document = WithImage("/BitsPerComponent 8 /Filter /JPXDecode /SMask 7 0 R", [1, 2, 3],
            more: pdf => pdf.Stream(7, $"/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Matte {matte}", [1, 2, 3]));
        var result = new PdfRedactor(document, images: new FakeCodec(Eight(60, 60, 60, 255))).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var image = RedactionKit.Images(output).Single().Stream!;
        var written = output.Stream(image.Dictionary, "SMask")!.Dictionary["Matte"];

        Assert.Equal(expected, written?.ToString());
    }

    [Fact]
    public void SharedImageGetsAPrivateCopyForTheMarkedUse()
    {
        var data = Gradient();
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources 7 0 R>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources 7 0 R>>");
        pdf.Stream(5, "", Place);
        pdf.Stream(6, "", Place + " " + Place.Replace("100 100", "300 300"));
        pdf.Obj(7, "<</XObject <</Im1 8 0 R>>>>");
        pdf.Stream(8, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8", data);
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfRedactor(document).Apply([TopLeft(0)]);
        using var output = RedactionKit.Open(result);
        Assert.Equal(0, Samples(output, 0)[0]);
        var second = RedactionKit.Images(output, 1);
        Assert.Equal(2, second.Count);
        Assert.All(second, i => Assert.Equal(data, output.Data(i.Stream!)));
        Assert.NotSame(RedactionKit.Images(output, 0).Single().Stream, second[0].Stream);
    }

    [Fact]
    public void JpegGoesThroughTheCodecAndComesBackAsFlate()
    {
        var jpeg = Convert.FromBase64String(StampKit.SampleJpeg);
        var rgba = Enumerable.Range(0, 8 * 6).SelectMany(_ => new byte[] { 200, 100, 50, 255 }).ToArray();
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg));
        var result = new PdfRedactor(document, images: new FakeCodec(new PdfRgbaImage(8, 6, rgba))).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var image = RedactionKit.Images(output).Single().Stream!;
        Assert.Equal("FlateDecode", output.Name(image.Dictionary, "Filter"));
        var samples = output.Data(image);
        Assert.Equal(8 * 6 * 3, samples.Length);
        Assert.Equal(new byte[] { 0, 0, 0 }, samples[..3]);
        Assert.Equal(new byte[] { 200, 100, 50 }, samples[(5 * 3)..(6 * 3)]);
        Assert.DoesNotContain(output.ObjectNumbers.Select(output.Get).OfType<PdfStream>(), s => output.RawData(s).AsSpan().IndexOf(jpeg.AsSpan(0, 24)) >= 0);
    }

    [Fact]
    public void JpegWithoutACodecIsRemoved()
    {
        var jpeg = Convert.FromBase64String(StampKit.SampleJpeg);
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg));
        var result = new PdfRedactor(document).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        Assert.Empty(RedactionKit.Images(output));
        Assert.Empty(ImageStreams(output));
        Assert.Equal(1, result.Report.Images);
        Assert.Equal(1, result.Report.Pages.Single().WholeImages);
    }

    [Fact]
    public void FailedDecodeRemovesTheImage()
    {
        var jpeg = Convert.FromBase64String(StampKit.SampleJpeg);
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf =>
            pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg));
        var result = new PdfRedactor(document, images: new FakeCodec(null)).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        Assert.Empty(RedactionKit.Images(output));
        Assert.Empty(ImageStreams(output));
        Assert.Equal(1, result.Report.Pages.Single().WholeImages);
        Assert.Contains(RedactionText.WholePicture(0, 1), result.Report.ToString());
    }

    [Theory]
    [InlineData("JBIG2Decode", false)]
    [InlineData("JBIG2Decode", true)]
    [InlineData("JPXDecode", false)]
    [InlineData("JPXDecode", true)]
    public void PictureThatCannotBeDecodedIsRemoved(string filter, bool codec)
    {
        using var document = RedactionKit.Page(Place, "/XObject <</Im1 6 0 R>>", pdf =>
            pdf.Stream(6, $"/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /{filter}", [1, 2, 3, 4, 5, 6]));
        var result = new PdfRedactor(document, images: codec ? new FakeCodec(null) : null).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        Assert.Empty(RedactionKit.Images(output));
        Assert.Empty(ImageStreams(output));
        Assert.Equal(1, result.Report.Images);
        Assert.Equal(1, result.Report.Pages.Single().WholeImages);
    }

    private static PdfRgbaImage Eight(byte r, byte g, byte b, byte a) =>
        new(8, 8, [.. Enumerable.Range(0, 64).SelectMany(_ => new[] { r, g, b, a })]);

    [Theory]
    [InlineData("[/Indexed /DeviceRGB 1 <000000FFFFFF>]")]
    [InlineData("[/Separation /Spot /DeviceRGB <</FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [1 0 0] /N 1>>]")]
    [InlineData("[/Lab <</WhitePoint [0.95 1 1.09]>>]")]
    public void AJpxPictureInASpaceThePixelsCannotShowIsRemovedWhole(string space)
    {
        using var document = WithImage($"/ColorSpace {space} /BitsPerComponent 8 /Filter /JPXDecode", [1, 2, 3]);
        var result = new PdfRedactor(document, images: new FakeCodec(Eight(1, 2, 3, 255))).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);

        Assert.Empty(RedactionKit.Images(output));
        Assert.Empty(ImageStreams(output));
        Assert.Equal(1, result.Report.Pages.Single().WholeImages);
    }

    [Theory]
    [InlineData("/SMaskInData 0", 255, false)]
    [InlineData("", 255, false)]
    [InlineData("/SMaskInData 1", 128, true)]
    public void AJpxPictureKeepsItsAlphaAsSMaskInDataSays(string entry, int alpha, bool softMask)
    {
        using var document = WithImage($"/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode {entry}", [1, 2, 3]);
        var result = new PdfRedactor(document, images: new FakeCodec(Eight(60, 40, 20, (byte)alpha))).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        var image = RedactionKit.Images(output).Single().Stream!;

        Assert.Equal(softMask, output.Stream(image.Dictionary, "SMask") is not null);
        Assert.False(image.Dictionary.ContainsKey("SMaskInData"));
        Assert.Equal([60, 40], output.Data(image)[(5 * 3)..(5 * 3 + 2)].Select(b => (int)b));
        Assert.Equal([0, 0, 0], output.Data(image)[..3].Select(b => (int)b));
    }

    [Theory]
    [InlineData("/SMaskInData 2", 128)]
    [InlineData("/SMaskInData 0", 0)]
    [InlineData("/SMaskInData -1", 128)]
    [InlineData("", 100)]
    public void AJpxPictureWhoseAlphaCannotBeReadAsTheFileSaysIsRemovedWhole(string entry, int alpha)
    {
        using var document = WithImage($"/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode {entry}", [1, 2, 3]);
        var result = new PdfRedactor(document, images: new FakeCodec(Eight(60, 40, 20, (byte)alpha))).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);

        Assert.Empty(RedactionKit.Images(output));
        Assert.Empty(ImageStreams(output));
        Assert.Equal(1, result.Report.Pages.Single().WholeImages);
    }

    [Fact]
    public void ImageOutsideTheMarkIsLeftAlone()
    {
        var data = Gradient();
        using var document = WithImage("/ColorSpace /DeviceGray /BitsPerComponent 8", data);
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, new PdfRect(300, 300, 400, 400))]);
        using var output = RedactionKit.Open(result);
        Assert.Equal(data, Samples(output));
        Assert.Equal(0, result.Report.Images);
    }

    [Fact]
    public void InlineImageUnderTheMarkIsRemoved()
    {
        string content = "q 160 0 0 160 100 100 cm BI /W 2 /H 2 /CS /G /BPC 8 ID \u0001\u0002\u0003\u0004\nEI Q BT /F1 12 Tf 50 50 Td (kept) Tj ET";
        using var document = RedactionKit.Page(content);
        Assert.Single(RedactionKit.Images(document));
        var result = new PdfRedactor(document).Apply([TopLeft()]);
        using var output = RedactionKit.Open(result);
        Assert.Empty(RedactionKit.Images(output));
        Assert.Equal("kept", RedactionKit.Text(output));
    }
}
