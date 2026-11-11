using System.IO;
using System.Windows;
using System.Windows.Ink;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.FillSign;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The picture of a signature: typed, drawn, or taken from a photo.
public sealed class SignatureArtTests
{
    private static PdfRgbaImage Blank(int width, int height) => new(width, height, new byte[width * height * 4]);

    private static int Opaque(PdfRgbaImage image) =>
        Enumerable.Range(0, image.Width * image.Height).Count(i => image.Rgba[i * 4 + 3] > 128);

    [Fact]
    public void ATypedNameBecomesInkOnClear()
    {
        OnSta.Run(() =>
        {
            var image = SignatureArt.Typed("Ada Lovelace", "Segoe UI")!;

            Assert.True(image.Width > image.Height);
            Assert.True(Opaque(image) > 100);
            Assert.True(image.Rgba[3] < 8);
        });
    }

    [Fact]
    public void NothingTypedIsNoSignature()
    {
        OnSta.Run(() => Assert.Null(SignatureArt.Typed("   ", "Segoe UI")));
    }

    [Fact]
    public void AStrokeIsDrawnBlackAndCutToItsSize()
    {
        OnSta.Run(() =>
        {
            var stroke = new Stroke(new StylusPointCollection([new StylusPoint(10, 10), new StylusPoint(110, 40)]));
            stroke.DrawingAttributes.Color = System.Windows.Media.Colors.Red;

            var image = SignatureArt.Drawn(new StrokeCollection([stroke]))!;

            Assert.InRange(image.Width, 300, 400);
            Assert.InRange(image.Height, 80, 200);
            Assert.True(Opaque(image) > 100);
            Assert.All(Enumerable.Range(0, image.Width * image.Height).Where(i => image.Rgba[i * 4 + 3] > 128), i => Assert.True(image.Rgba[i * 4] < 10));
        });
    }

    [Fact]
    public void NoStrokesIsNoSignature()
    {
        OnSta.Run(() => Assert.Null(SignatureArt.Drawn([])));
    }

    [Fact]
    public void PaperGoesClearAndInkStays()
    {
        byte[] pixels = [255, 255, 255, 255, 20, 20, 20, 255, 200, 200, 200, 255];

        var cleared = SignatureArt.PaperToClear(new PdfRgbaImage(3, 1, pixels));

        Assert.Equal(0, cleared.Rgba[3]);
        Assert.Equal(255, cleared.Rgba[7]);
        Assert.InRange(cleared.Rgba[11], 1, 254);
    }

    [Fact]
    public void TrimKeepsTheInkAndAThinBorder()
    {
        var image = Blank(40, 30);
        image.Rgba[(15 * 40 + 20) * 4 + 3] = 255;

        var trimmed = SignatureArt.Trim(image);

        Assert.Equal(9, trimmed.Width);
        Assert.Equal(9, trimmed.Height);
        Assert.Equal(255, trimmed.Rgba[(4 * 9 + 4) * 4 + 3]);
    }

    [Fact]
    public void AnEmptyPictureIsLeftAlone()
    {
        var image = Blank(5, 5);

        Assert.Same(image, SignatureArt.Trim(image));
    }

    [Fact]
    public void APhotoOfInkOnPaperBecomesInkOnClear()
    {
        OnSta.Run(() =>
        {
            var photo = new PdfRgbaImage(30, 20, Enumerable.Repeat((byte)250, 30 * 20 * 4).ToArray());
            for (int x = 5; x < 25; x++)
            {
                int at = (10 * 30 + x) * 4;
                photo.Rgba[at] = photo.Rgba[at + 1] = photo.Rgba[at + 2] = 10;
            }

            var made = SignatureArt.FromFile(SignatureArt.ToPng(photo))!;

            Assert.InRange(made.Width, 20, 30);
            Assert.True(made.Rgba[3] < 8 || made.Rgba[3] == 255);
            Assert.InRange(Opaque(made), 15, 30 * 20);
            Assert.True(Opaque(made) < made.Width * made.Height);
        });
    }

    [Fact]
    public void AFileThatIsNotAPictureGivesNothing()
    {
        OnSta.Run(() => Assert.Null(SignatureArt.FromFile([1, 2, 3, 4])));
    }

    private static byte[] Jpeg(int width, int height, ushort? orientation)
    {
        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgr24, null, new byte[width * height * 3], width * 3);
        BitmapMetadata? metadata = null;
        if (orientation is { } value)
        {
            metadata = new BitmapMetadata("jpg");
            metadata.SetQuery("/app1/ifd/{ushort=274}", value);
        }
        var encoder = new JpegBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap, null, metadata, null));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    [Theory]
    [InlineData(null, 24, 8)]
    [InlineData(1, 24, 8)]
    [InlineData(6, 8, 24)]
    [InlineData(8, 8, 24)]
    [InlineData(3, 24, 8)]
    public void APhotoIsTurnedTheWayItsCameraSaidWhenItWasTaken(int? orientation, int width, int height)
    {
        OnSta.Run(() =>
        {
            var image = SignatureArt.FromFile(Jpeg(24, 8, (ushort?)orientation))!;

            Assert.Equal((width, height), (image.Width, image.Height));
        });
    }

    [Fact]
    public void TurningAPictureSwapsItsSidesAndFourTurnsComeBack()
    {
        OnSta.Run(() =>
        {
            var wide = new PdfRgbaImage(4, 2, [.. Enumerable.Range(0, 32).Select(i => (byte)i)]);

            var turned = SignatureArt.Turn(wide);

            Assert.Equal((2, 4), (turned.Width, turned.Height));
            // The top left pixel of a picture turned clockwise lands top right.
            Assert.Equal(wide.Rgba[0..4], turned.Rgba[4..8]);
            var back = SignatureArt.Turn(SignatureArt.Turn(SignatureArt.Turn(turned)));
            Assert.Equal(wide.Rgba, back.Rgba);
        });
    }

    private static byte[] Jpeg(ushort orientation)
    {
        var metadata = new BitmapMetadata("jpg");
        metadata.SetQuery("System.Photo.Orientation", orientation);
        var source = BitmapSource.Create(4, 2, 96, 96, PixelFormats.Bgra32, null, new byte[32], 16);
        var encoder = new JpegBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source, null, metadata, null));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    [Fact]
    public void ASidewaysCameraJpegIsTurnedUpright()
    {
        OnSta.Run(() =>
        {
            var upright = SignatureArt.UprightFile(Jpeg(6));

            var frames = new WicImageCodec().DecodeFile(upright)!;
            Assert.Equal((2, 4), (frames[0].Width, frames[0].Height));
        });
    }

    [Fact]
    public void AnUprightJpegAndAPngAreLeftAlone()
    {
        OnSta.Run(() =>
        {
            var jpeg = Jpeg(1);
            var png = SignatureArt.ToPng(Blank(4, 2));

            Assert.Same(jpeg, SignatureArt.UprightFile(jpeg));
            Assert.Same(png, SignatureArt.UprightFile(png));
        });
    }
}
