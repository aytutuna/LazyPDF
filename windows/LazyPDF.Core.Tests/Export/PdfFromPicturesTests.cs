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

    [Theory]
    [InlineData(200, 300, 200, 300)]
    [InlineData(1, 99999, 3, 14400)]
    [InlineData(double.NaN, 50, 3, 50)]
    public void CustomPaperIsClamped(double width, double height, double expectedW, double expectedH)
    {
        var setup = new PdfPageSetup(PdfPaper.Custom, PdfOrientation.Portrait, 0, width, height);
        var (document, _) = Reopen(PdfFromPictures.Create([ExportFakeCodec.Picture(2, 2)], Codec, setup));
        var page = document.Pages[0].MediaBox;
        Assert.Equal((expectedW, expectedH), (page.Width, page.Height));
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
    public void AFrameTooBigToDecodeIsLeftOutAndCounted()
    {
        var made = PdfFromPictures.Create([[(byte)'B', 2]], Codec);
        Assert.Equal(2, made.Pages);
        Assert.Equal(1, made.SkippedFrames);
        Assert.Empty(made.Unreadable);
    }

    [Fact]
    public void AFileOfOnlyTooBigFramesIsUnreadableAndCounted()
    {
        var made = PdfFromPictures.Create([ExportFakeCodec.Picture(4, 4), [(byte)'B', 0]], Codec);
        Assert.Equal(1, made.Pages);
        Assert.Equal(1, made.SkippedFrames);
        Assert.Equal([1], made.Unreadable);
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

    // The sample JPEG with an Exif block after its JFIF header that carries the given orientation.
    private static byte[] Oriented(int orientation, int xDpi = 0, int yDpi = 0)
    {
        var jpeg = Jpeg();
        if (xDpi > 0) (jpeg[13], jpeg[14], jpeg[15], jpeg[16], jpeg[17]) = (1, (byte)(xDpi >> 8), (byte)xDpi, (byte)(yDpi >> 8), (byte)yDpi);
        byte[] exif = [0xFF, 0xE1, 0, 34, (byte)'E', (byte)'x', (byte)'i', (byte)'f', 0, 0, (byte)'M', (byte)'M', 0, 42, 0, 0, 0, 8,
            0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, (byte)orientation, 0, 0, 0, 0, 0, 0];
        int at = 4 + (jpeg[4] << 8 | jpeg[5]);
        return [.. jpeg[..at], .. exif, .. jpeg[at..]];
    }

    [Fact]
    public void ExifOrientationTurnsThePictureAndChoosesThePageShape()
    {
        var file = Oriented(6);
        var made = PdfFromPictures.Create([file], Codec, new PdfPageSetup(Margin: 0));
        var (document, images) = Reopen(made);
        var page = document.Pages[0].MediaBox;
        Assert.True(page.Height > page.Width);
        var m = images[0].Matrix;
        Assert.Equal(0, m.A, 6);
        Assert.Equal(0, m.D, 6);
        Assert.Equal(6 * 72 / 96.0, m.C, 6);
        Assert.Equal(-8 * 72 / 96.0, m.B, 6);
        Assert.Equal(file, document.RawData(images[0].Stream!));
    }

    [Fact]
    public void AMirroredOrientationFlipsTheMatrixAndFitToPictureSwapsSides()
    {
        var made = PdfFromPictures.Create([Oriented(2), Oriented(8)], Codec, new PdfPageSetup(PdfPaper.Picture, Margin: 0));
        var (document, images) = Reopen(made);
        Assert.True(images[0].Matrix.A < 0);
        var turned = document.Pages[1].MediaBox;
        Assert.Equal(6 * 72 / 96.0, turned.Width, 6);
        Assert.Equal(8 * 72 / 96.0, turned.Height, 6);
    }

    [Fact]
    public void DensityOfBothAxesIsUsed()
    {
        var made = PdfFromPictures.Create([Oriented(1, 200, 100)], Codec, new PdfPageSetup(Margin: 0));
        var box = Reopen(made).Images[0].Bounds;
        Assert.Equal(8 * 72 / 200.0, box.Width, 4);
        Assert.Equal(6 * 72 / 100.0, box.Height, 4);
    }

    [Theory]
    [InlineData(300, 300, 24, 24)]
    [InlineData(72, 72, 100, 100)]
    [InlineData(300, 150, 24, 48)]
    [InlineData(0, 0, 75, 75)]
    [InlineData(5000, 5000, 75, 75)]
    [InlineData(300, 5000, 75, 75)]
    public void ADecodedFrameIsPlacedAtTheDensityItCarries(int dpiX, int dpiY, double width, double height)
    {
        var made = PdfFromPictures.Create([ExportFakeCodec.Picture(100, 100, 128, dpiX, dpiY)], Codec, new PdfPageSetup(PdfPaper.Picture, Margin: 0));
        var box = Reopen(made).Images[0].Bounds;
        Assert.Equal(width, box.Width, 4);
        Assert.Equal(height, box.Height, 4);
    }

    [Theory]
    [InlineData(300)]
    [InlineData(297.638)]
    public void AMarginThatLeavesNoRoomIsRefused(double margin)
    {
        Assert.Throws<ArgumentException>(() => PdfFromPictures.Create([Jpeg()], Codec, new PdfPageSetup(Margin: margin)));
    }

    [Fact]
    public void ACancelledTokenStopsTheMakingOfThePdf()
    {
        using var source = new CancellationTokenSource();
        source.Cancel();
        Assert.Throws<OperationCanceledException>(() => PdfFromPictures.Create([Jpeg()], Codec, cancellation: source.Token));
    }

    [Fact]
    public void ACancelDuringTheFirstDecodeStopsBeforeTheThirdFile()
    {
        using var source = new CancellationTokenSource();
        var codec = new CancellingCodec(source);
        var file = ExportFakeCodec.Picture(4, 4);
        Assert.Throws<OperationCanceledException>(() => PdfFromPictures.Create([file, file, file], codec, cancellation: source.Token));
        Assert.Equal(1, codec.Files);
    }

    private sealed class CancellingCodec(CancellationTokenSource source) : IImageCodec
    {
        public int Files { get; private set; }

        public PdfRgbaImage? Decode(byte[] data, string codec) => null;

        public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file)
        {
            Files++;
            source.Cancel();
            return Codec.DecodeFile(file);
        }

        public byte[] EncodeJpeg(PdfRgbaImage image, int quality) => [];
    }}
