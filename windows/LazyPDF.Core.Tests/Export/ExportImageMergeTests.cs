using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Hands back the same RGBA pixels for every coded stream it is asked to read.</summary>
internal sealed class ExportRgbaCodec(int width, params byte[] rgba) : IImageCodec
{
    public PdfRgbaImage? Decode(byte[] data, string codec) => new(width, rgba.Length / 4 / width, rgba);

    public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file) => null;

    public byte[] EncodeJpeg(PdfRgbaImage image, int quality) => throw new NotSupportedException();
}

public class ExportImageMergeTests
{
    private const string Image = "/Type /XObject /Subtype /Image";

    private static PdfDocument Open(string content, Action<TestPdf> objects, string resources = "/XObject <</Im 10 0 R>>", string pageEntries = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R {pageEntries} /Resources <<{resources}>> /Contents 30 0 R>>");
        pdf.Stream(30, "", content);
        objects(pdf);
        return PdfDocument.Open(pdf.Finish());
    }

    private static ExportImage? Extract(string entries, byte[] data, IImageCodec? codec, Action<TestPdf>? more = null)
    {
        var document = Open("q 10 0 0 10 0 0 cm /Im Do Q", pdf =>
        {
            pdf.Stream(10, $"{Image} {entries}", data);
            more?.Invoke(pdf);
        });
        return ImageExtractor.Extract(document, codec: codec).SingleOrDefault()?.Image;
    }

    private static byte[] Rgba(ExportImage? image) => ExportKit.PngDecode(Assert.IsType<ExportImage>(image).Data).Rgba;

    [Fact]
    public void AColourSpaceThatIsAStreamSkipsTheImageInsteadOfAbortingTheRun()
    {
        var document = Open("q 10 0 0 10 0 0 cm BI /W 1 /H 1 /CS /Cs1 /BPC 8 ID x EI Q", pdf => pdf.Stream(11, "", "abc"), "/ColorSpace <</Cs1 11 0 R>>");
        Assert.Empty(ImageExtractor.Extract(document));
        Assert.Empty(ExportLayout.Analyze(document).Pages[0].Pictures);
    }

    [Fact]
    public void ACmykJpegIsTakenAsTheCodecReadsIt()
    {
        var codec = new ExportRgbaCodec(1, 200, 100, 50, 255);
        var inverted = Extract("/Width 1 /Height 1 /ColorSpace /DeviceCMYK /BitsPerComponent 8 /Filter /DCTDecode /Decode [1 0 1 0 1 0 1 0]", [1], codec);
        Assert.Equal([200, 100, 50, 255], Rgba(inverted));
    }

    [Fact]
    public void AColourKeyOnACmykJpegIsNotComparedWithTheCodecsRgb()
    {
        var png = Extract("/Width 1 /Height 1 /ColorSpace /DeviceCMYK /BitsPerComponent 8 /Filter /DCTDecode /Mask [0 0 0 0 0 0 0 0]", [1],
            new ExportRgbaCodec(1, 0, 0, 0, 255));
        Assert.Equal([0, 0, 0, 255], Rgba(png));
    }

    [Fact]
    public void ADecodeArrayOnAJpxImageIsIgnored()
    {
        var png = Extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /Filter /JPXDecode /Decode [1 0 1 0 1 0]", [1], new ExportRgbaCodec(1, 10, 20, 30, 255));
        Assert.Equal([10, 20, 30, 255], Rgba(png));
    }

    [Fact]
    public void AJpxImageKeepsItsOwnAlphaOnlyWhenTheFileAsksFor()
    {
        var codec = new ExportRgbaCodec(1, 10, 20, 30, 40);
        Assert.Equal([10, 20, 30, 40], Rgba(Extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /Filter /JPXDecode /SMaskInData 1", [1], codec)));
        Assert.Equal([10, 20, 30, 255], Rgba(Extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /Filter /JPXDecode", [1], codec)));
    }

    [Fact]
    public void AColourKeyOnABilevelCodecImageMatchesItsOwnDepth()
    {
        var png = Extract("/Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode /Mask [1 1]", [1], new ExportPixelCodec(2, 0, 255));
        Assert.Equal([255, 0], Rgba(png).Where((_, i) => i % 4 == 3));
    }

    [Fact]
    public void AnIndexedBilevelCodecImageReadsItsPaletteByTheStoredSample()
    {
        var png = Extract("/Width 2 /Height 1 /ColorSpace [/Indexed /DeviceRGB 3 <000000 FF0000 00FF00 0000FF>] /BitsPerComponent 1 /Filter /JBIG2Decode", [1],
            new ExportPixelCodec(2, 0, 255));
        Assert.Equal([0, 0, 0, 255, 255, 0, 0, 255], Rgba(png));
    }

    [Fact]
    public void ASoftMaskWithTheShortFilterNameIsReadThroughTheCodec()
    {
        var png = Extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /SMask 11 0 R", TestPdf.Deflate([9, 8, 7]), new ExportPixelCodec(1, 128),
            pdf => pdf.Stream(11, $"{Image} /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCT", [1]));
        Assert.Equal([9, 8, 7, 128], Rgba(png));
    }

    [Fact]
    public void ADecodedImageWithAnUnreadableColourSpaceIsStillExported()
    {
        var png = Extract("/Width 1 /Height 1 /ColorSpace [/CalCMYK <<>>] /Filter /JPXDecode", [1], new ExportRgbaCodec(1, 10, 20, 30, 255));
        Assert.Equal([10, 20, 30, 255], Rgba(png));
    }

    private static List<ImageInfo> Infos(PdfDocument document)
    {
        var scan = new ExportScan(new PageGeometry(document.Pages[0]), false);
        new ContentInterpreter(document).Run(document.Pages[0], scan);
        return scan.Images;
    }

    private static PdfDocument Flate(int count, string extra = "", Action<TestPdf>? more = null) => Open(string.Concat(Enumerable.Range(0, count).Select(i => $"/Im{i} Do ")), pdf =>
    {
        for (int i = 0; i < count; i++) pdf.Stream(10 + i, $"{Image} /Width 10 /Height 10 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode {extra}", TestPdf.Deflate(new byte[100]));
        more?.Invoke(pdf);
    }, "/XObject <<" + string.Concat(Enumerable.Range(0, count).Select(i => $"/Im{i} {10 + i} 0 R ")) + ">>");

    [Fact]
    public void OnlyPixelsThatAreDecodedUseUpThePixelBudget()
    {
        var document = Open("/Big Do /Small Do", pdf =>
        {
            pdf.Stream(10, $"{Image} /Width 1000 /Height 1000 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", [1]);
            pdf.Stream(11, $"{Image} /Width 10 /Height 10 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.Deflate(new byte[100]));
        }, "/XObject <</Big 10 0 R /Small 11 0 R>>");
        var infos = Infos(document);
        var images = new ExportImages(document, null, pixelBudget: 100);
        Assert.NotNull(images.Get(infos[0], 6));
        Assert.NotNull(images.Get(infos[0]));
        Assert.NotNull(images.Get(infos[1]));
    }

    [Fact]
    public void ImagesPastThePixelBudgetAreLeftOut()
    {
        var document = Flate(5);
        var images = new ExportImages(document, null, pixelBudget: 250);
        Assert.Equal([true, true, false, false, false], Infos(document).Select(i => images.Get(i) is not null));
    }

    [Fact]
    public void AMaskSharedByManyImagesIsChargedForEachDecode()
    {
        var document = Flate(8, "/SMask 40 0 R", pdf => pdf.Stream(40, $"{Image} /Width 10 /Height 10 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.Deflate(new byte[100])));
        var images = new ExportImages(document, null, pixelBudget: 450);
        Assert.Equal(2, Infos(document).Count(i => images.Get(i) is not null));
    }

    [Fact]
    public void ACancelledRunStopsBeforeTheNextDecode()
    {
        var document = Flate(2);
        using var source = new CancellationTokenSource();
        var images = new ExportImages(document, null, source.Token);
        var infos = Infos(document);
        Assert.NotNull(images.Get(infos[0]));
        source.Cancel();
        Assert.Throws<OperationCanceledException>(() => images.Get(infos[1]));
    }

    [Fact]
    public void JpegScansOnRotatedPagesAreNotLostToThePixelBudget()
    {
        var pdf = new TestPdf();
        const int pages = 40;
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, $"<</Type /Pages /Kids [{string.Join(" ", Enumerable.Range(0, pages).Select(i => $"{100 + i} 0 R"))}] /Count {pages} /MediaBox [0 0 612 792] /Rotate 90>>");
        for (int i = 0; i < pages; i++)
        {
            pdf.Obj(100 + i, $"<</Type /Page /Parent 2 0 R /Resources <</XObject <</Im {200 + i} 0 R>>>> /Contents {300 + i} 0 R>>");
            pdf.Stream(300 + i, "", "q 612 0 0 792 0 0 cm /Im Do Q");
            pdf.Stream(200 + i, $"{Image} /Width 2550 /Height 3300 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", [1]);
        }
        var result = ExportLayout.Analyze(PdfDocument.Open(pdf.Finish()));
        Assert.All(result.Pages, p => Assert.Single(p.Pictures));
    }

    [Fact]
    public void ARotatedJpegPastTheLimitsStaysAJpeg()
    {
        var document = Open("/Im Do", pdf => pdf.Stream(10, $"{Image} /Width 100 /Height 100 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", [1]));
        var images = new ExportImages(document, new ExportRgbaCodec(4, new byte[64]), pixelBudget: 10);
        Assert.True(Assert.IsType<ExportImage>(images.Get(Infos(document)[0], 6)).IsJpeg);
    }

    [Theory]
    [InlineData("/Width 100000 /Height 100000")]
    [InlineData("/Width -1000000 /Height 1000000")]
    public void AMaskOfAbsurdSizeDoesNotSpendOrCreditThePixelBudget(string size)
    {
        var document = Open(string.Concat(Enumerable.Range(0, 6).Select(i => $"/Im{i} Do ")), pdf =>
        {
            pdf.Stream(40, $"{Image} {size} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.Deflate(new byte[100]));
            for (int i = 0; i < 6; i++)
            {
                string mask = i == 0 ? "/SMask 40 0 R" : "";
                pdf.Stream(10 + i, $"{Image} /Width 10 /Height 10 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode {mask}", TestPdf.Deflate(new byte[100]));
            }
        }, "/XObject <<" + string.Concat(Enumerable.Range(0, 6).Select(i => $"/Im{i} {10 + i} 0 R ")) + ">>");
        var images = new ExportImages(document, null, pixelBudget: 250);
        Assert.Equal(1, Infos(document).Count(i => images.Get(i) is not null));
    }

    [Fact]
    public void ACodecImageIsChargedForThePixelsItDecodesTo()
    {
        var document = Open("/A Do /B Do /C Do", pdf =>
        {
            foreach (int id in new[] { 10, 11, 12 }) pdf.Stream(id, $"{Image} /Width 1 /Height 1 /ColorSpace /DeviceRGB /Filter /JPXDecode", [(byte)id]);
        }, "/XObject <</A 10 0 R /B 11 0 R /C 12 0 R>>");
        var images = new ExportImages(document, new ExportRgbaCodec(10, new byte[400]), pixelBudget: 150);
        Assert.Equal([true, false, false], Infos(document).Select(i => images.Get(i) is not null));
    }

    [Fact]
    public void ASidewaysJpegIsNotStretchedIntoTheTurnedBox()
    {
        var document = Open("q 612 0 0 792 0 0 cm /Im Do Q", pdf => pdf.Stream(10, $"{Image} /Width 612 /Height 792 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", [1]),
            pageEntries: "/Rotate 90");
        var picture = Assert.Single(ExportLayout.Analyze(document).Pages[0].Pictures);
        Assert.True(picture.Image.IsJpeg);
        Assert.Equal(612.0 / 792, picture.Bounds.Width / picture.Bounds.Height, 3);
    }

    [Fact]
    public void ATinyPictureOnPicturePaperMakesAPage()
    {
        var made = PdfFromPictures.Create([ExportFakeCodec.Picture(1, 1)], new ExportFakeCodec(), new PdfPageSetup(PdfPaper.Picture));
        Assert.Equal(1, made.Pages);
        Assert.Throws<ArgumentException>(() => PdfFromPictures.Create([ExportFakeCodec.Picture(1, 1)], new ExportFakeCodec(), new PdfPageSetup(PdfPaper.Picture, Margin: 8000)));
    }
}
