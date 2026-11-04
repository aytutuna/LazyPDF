using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class PdfFromPicturesTests
{
    private static readonly ExportFakeCodec Codec = new();

    private static (PdfDocument Document, List<ImageInfo> Images) Reopen(PicturesPdf made, int page = 0)
    {
        var document = PdfDocument.Open(made.Bytes);
        var recorder = new Recorder();
        new ContentInterpreter(document).Run(document.Pages[page], recorder);
        return (document, recorder.Images);
    }

    private static byte[] Jpeg(int dpi = 0)
    {
        var bytes = ExportKit.Jpeg;
        if (dpi > 0) (bytes[13], bytes[14], bytes[15], bytes[16], bytes[17]) = (1, (byte)(dpi >> 8), (byte)dpi, (byte)(dpi >> 8), (byte)dpi);
        return bytes;
    }

    [Fact]
    public void AJpegGoesInWithoutBeingEncodedAgain()
    {
        var made = PdfFromPictures.Create([Jpeg()], Codec);
        var (document, images) = Reopen(made);
        var image = Assert.Single(images);
        Assert.Equal(ExportKit.Jpeg, document.RawData(image.Stream!));
        Assert.Equal("DCTDecode", ((PdfName)image.Dictionary["Filter"]!).Value);
        Assert.Empty(Codec.Decoded);
    }

    [Fact]
    public void ThePictureIsCentredAtItsNaturalSizeOnA4()
    {
        var made = PdfFromPictures.Create([Jpeg(300)], Codec, new PdfPageSetup(Orientation: PdfOrientation.Portrait, Margin: 0));
        var (document, images) = Reopen(made);
        var page = document.Pages[0].MediaBox;
        Assert.Equal((595.276, 841.89), (page.Width, page.Height));
        double w = 8 * 72 / 300.0, h = 6 * 72 / 300.0;
        var box = images[0].Bounds;
        Assert.Equal(w, box.Width, 4);
        Assert.Equal(h, box.Height, 4);
        Assert.Equal((595.276 - w) / 2, box.Left, 4);
        Assert.Equal((841.89 - h) / 2, box.Bottom, 4);
    }

    [Fact]
    public void ABigPictureShrinksIntoTheMargin()
    {
        var file = ExportFakeCodec.Picture(255, 20);
        var made = PdfFromPictures.Create([file], Codec, new PdfPageSetup(PdfPaper.Letter, PdfOrientation.Portrait, 250));
        var (document, images) = Reopen(made);
        var page = document.Pages[0].MediaBox;
        Assert.Equal((612, 792), (page.Width, page.Height));
        Assert.Equal(112, images[0].Bounds.Width, 6);
        Assert.Equal(112.0 * 20 / 255, images[0].Bounds.Height, 6);
        Assert.Equal(306, (images[0].Bounds.Left + images[0].Bounds.Right) / 2, 6);
    }

    [Fact]
    public void FitToPictureSizesThePageToThePictureAndMargin()
    {
        var made = PdfFromPictures.Create([ExportFakeCodec.Picture(96, 48)], Codec, new PdfPageSetup(PdfPaper.Picture, Margin: 10));
        var page = PdfDocument.Open(made.Bytes).Pages[0].MediaBox;
        Assert.Equal((72 + 20, 36 + 20), (page.Width, page.Height));
    }

    [Fact]
    public void OrientationFollowsThePictureOrIsForced()
    {
        var wide = ExportFakeCodec.Picture(40, 10);
        var auto = PdfDocument.Open(PdfFromPictures.Create([wide], Codec).Bytes).Pages[0].MediaBox;
        var portrait = PdfDocument.Open(PdfFromPictures.Create([wide], Codec, new PdfPageSetup(Orientation: PdfOrientation.Portrait)).Bytes).Pages[0].MediaBox;
        var landscape = PdfDocument.Open(PdfFromPictures.Create([ExportFakeCodec.Picture(10, 40)], Codec, new PdfPageSetup(Orientation: PdfOrientation.Landscape)).Bytes).Pages[0].MediaBox;
        Assert.True(auto.Width > auto.Height);
        Assert.True(portrait.Width < portrait.Height);
        Assert.True(landscape.Width > landscape.Height);
    }

    [Fact]
    public void OnePageForEachFileInOrderAndUnreadableFilesAreReported()
    {
        var made = PdfFromPictures.Create([ExportFakeCodec.Picture(4, 4, 10), [1, 2, 3], Jpeg(), ExportFakeCodec.Picture(4, 4, 200)], Codec);
        Assert.Equal(3, made.Pages);
        Assert.Equal([1], made.Unreadable);
        using var reopened = PdfDocument.Open(made.Bytes);
        Assert.Equal(3, reopened.Pages.Count);
        Assert.Equal(ExportKit.Jpeg, reopened.RawData((PdfStream)reopened.Resolve(((PdfDictionary)reopened.Resolve(reopened.Pages[1].Resources!["XObject"])!)["Im1"])!));
    }

    [Fact]
    public void AFileOnlyTheCodecKnowsIsDecodedAndKeptLossless()
    {
        var made = PdfFromPictures.Create([ExportFakeCodec.Picture(3, 2, 77)], Codec);
        var (document, images) = Reopen(made);
        var samples = document.Data(images[0].Stream!);
        Assert.Equal(Enumerable.Repeat((byte)77, 18), samples);
    }

    [Fact]
    public void NothingReadableIsAnError()
    {
        var error = Assert.Throws<ArgumentException>(() => PdfFromPictures.Create([[1, 2, 3], []], Codec));
        Assert.Contains(ExportText.NoUsablePicture, error.Message);
        Assert.Throws<ArgumentException>(() => PdfFromPictures.Create([], Codec));
        Assert.Throws<ArgumentException>(() => PdfFromPictures.Create([Jpeg()], Codec, new PdfPageSetup(Margin: -1)));
    }

    [Fact]
    public void ABrokenJpegFallsBackToTheCodec()
    {
        var broken = new byte[] { 0xFF, 0xD8, 0xFF, 0xD9 };
        var made = PdfFromPictures.Create([broken, Jpeg()], Codec);
        Assert.Equal(1, made.Pages);
        Assert.Equal([0], made.Unreadable);
    }

    [Fact]
    public void TheFileReopensInPdfPig()
    {
        var made = PdfFromPictures.Create([Jpeg(), ExportFakeCodec.Picture(5, 5)], Codec, new PdfPageSetup(PdfPaper.Letter));
        using var pig = PigDocument.Open(made.Bytes);
        Assert.Equal(2, pig.NumberOfPages);
        Assert.Equal(792, pig.GetPage(1).Width, 3);
        Assert.Single(pig.GetPage(1).GetImages());
        Assert.Single(pig.GetPage(2).GetImages());
    }
}
