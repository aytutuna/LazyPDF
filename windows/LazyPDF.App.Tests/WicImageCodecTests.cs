using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Export;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The picture codecs on WIC, with files made here.
public sealed class WicImageCodecTests
{
    private static readonly WicImageCodec Codec = new();

    private static PdfRgbaImage Gradient(int width, int height, byte alpha = 255)
    {
        var rgba = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int i = (y * width + x) * 4;
                rgba[i] = (byte)(x * 255 / Math.Max(1, width - 1));
                rgba[i + 1] = (byte)(y * 255 / Math.Max(1, height - 1));
                rgba[i + 2] = 40;
                rgba[i + 3] = alpha;
            }
        }
        return new PdfRgbaImage(width, height, rgba);
    }

    private static byte[] Encode(BitmapEncoder encoder, params PdfRgbaImage[] frames)
    {
        foreach (var frame in frames) encoder.Frames.Add(BitmapFrame.Create(Pixels.ToBitmap(frame)));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    [Fact]
    public void AJpegIsMadeAndReadBackAtTheSameSize()
    {
        byte[] jpeg = Codec.EncodeJpeg(Gradient(64, 48), 90);

        Assert.Equal(0xFF, jpeg[0]);
        Assert.Equal(0xD8, jpeg[1]);
        var back = Codec.DecodeFile(jpeg);
        var frame = Assert.Single(back!);
        Assert.Equal((64, 48), (frame.Width, frame.Height));
        Assert.True(Math.Abs(frame.Rgba[(10 * 64 + 20) * 4] - 20 * 255 / 63) < 12);
    }

    [Fact]
    public void ATiffIsMadeAndReadBack()
    {
        var back = Assert.Single(Codec.DecodeFile(Codec.EncodeTiff(Gradient(64, 48)))!);

        Assert.Equal((64, 48), (back.Width, back.Height));
        Assert.Equal(20 * 255 / 63, back.Rgba[(10 * 64 + 20) * 4]);
    }

    [Fact]
    public void ABmpIsMadeAndReadBack()
    {
        byte[] bmp = Codec.EncodeBmp(Gradient(64, 48));

        Assert.Equal((byte)'B', bmp[0]);
        var back = Assert.Single(Codec.DecodeFile(bmp)!);
        Assert.Equal((64, 48), (back.Width, back.Height));
        Assert.Equal(20 * 255 / 63, back.Rgba[(10 * 64 + 20) * 4]);
    }

    [Fact]
    public void TransparentPixelsAreWhiteInTiffAndBmp()
    {
        var clear = Gradient(8, 8, alpha: 0);

        foreach (var bytes in new[] { Codec.EncodeTiff(clear), Codec.EncodeBmp(clear) })
            Assert.Equal([255, 255, 255, 255], Assert.Single(Codec.DecodeFile(bytes)!).Rgba[..4]);
    }

    [Fact]
    public void GrayscaleOfRedIsNearItsLuma()
    {
        var red = new PdfRgbaImage(4, 4, Enumerable.Range(0, 16).SelectMany(_ => new byte[] { 255, 0, 0, 255 }).ToArray());

        var back = Assert.Single(Codec.DecodeFile(Codec.Encode(red, PictureFormat.Png, PictureColour.Grayscale, 0))!);

        Assert.InRange(back.Rgba[0], 74, 78);
        Assert.Equal(back.Rgba[0], back.Rgba[1]);
    }

    [Fact]
    public void BlackAndWhiteSplitsAtMiddleGray()
    {
        static PdfRgbaImage Flat(byte v) => new(8, 8, Enumerable.Range(0, 64).SelectMany(_ => new byte[] { v, v, v, 255 }).ToArray());

        foreach (var format in new[] { PictureFormat.Png, PictureFormat.Tiff })
        {
            var light = Assert.Single(Codec.DecodeFile(Codec.Encode(Flat(200), format, PictureColour.BlackWhite, 0))!);
            var dark = Assert.Single(Codec.DecodeFile(Codec.Encode(Flat(60), format, PictureColour.BlackWhite, 0))!);

            Assert.Equal([255, 255, 255], light.Rgba[..3]);
            Assert.Equal([0, 0, 0], dark.Rgba[..3]);
        }
    }

    [Fact]
    public void AGrayscaleTiffIsSmallerThanColour()
    {
        var flat = new PdfRgbaImage(400, 400, Enumerable.Range(0, 400 * 400).SelectMany(_ => new byte[] { 90, 140, 200, 255 }).ToArray());

        Assert.True(Codec.Encode(flat, PictureFormat.Tiff, PictureColour.Grayscale, 0).Length < Codec.Encode(flat, PictureFormat.Tiff, PictureColour.Colour, 0).Length);
    }

    [Fact]
    public void ALowerQualityIsSmaller()
    {
        var image = Gradient(128, 128);

        Assert.True(Codec.EncodeJpeg(image, 20).Length < Codec.EncodeJpeg(image, 95).Length);
    }

    [Fact]
    public void SeeThroughPixelsGoOntoWhiteInAJpeg()
    {
        byte[] jpeg = Codec.EncodeJpeg(new PdfRgbaImage(8, 8, Enumerable.Repeat((byte)0, 8 * 8 * 4).ToArray()), 95);

        var frame = Codec.DecodeFile(jpeg)![0];

        Assert.True(frame.Rgba[0] > 240 && frame.Rgba[1] > 240 && frame.Rgba[2] > 240);
    }

    [Fact]
    public void APngKeepsItsPixelsAndItsAlpha()
    {
        var image = Gradient(16, 16, alpha: 128);

        var frame = Codec.DecodeFile(Encode(new PngBitmapEncoder(), image))!.Single();

        Assert.Equal(image.Rgba, frame.Rgba);
    }

    [Fact]
    public void ATiffGivesEveryFrame()
    {
        byte[] tiff = Encode(new TiffBitmapEncoder(), Gradient(10, 10), Gradient(20, 12), Gradient(8, 8));

        var frames = Codec.DecodeFile(tiff)!;

        Assert.Equal([(10, 10), (20, 12), (8, 8)], frames.Select(f => (f.Width, f.Height)));
    }

    [Fact]
    public void ABmpAndAGifAreRead()
    {
        Assert.Single(Codec.DecodeFile(Encode(new BmpBitmapEncoder(), Gradient(9, 9)))!);
        Assert.Single(Codec.DecodeFile(Encode(new GifBitmapEncoder(), Gradient(9, 9)))!);
    }

    [Fact]
    public void ADctStreamIsDecodedAsAJpeg()
    {
        byte[] jpeg = Codec.EncodeJpeg(Gradient(32, 32), 90);

        var image = Codec.Decode(jpeg, "DCTDecode");

        Assert.Equal((32, 32), (image!.Width, image.Height));
        Assert.Null(Codec.Decode(jpeg, "JBIG2Decode"));
    }

    [Fact]
    public void WhatIsNotAPictureGivesNull()
    {
        Assert.Null(Codec.DecodeFile([]));
        Assert.Null(Codec.DecodeFile("this is text, not a picture"u8.ToArray()));
        Assert.Null(Codec.Decode([1, 2, 3], "DCTDecode"));
    }

    [Fact]
    public void ThePicturesOfAPdfFromPicturesRoundTrip()
    {
        byte[] jpeg = Codec.EncodeJpeg(Gradient(80, 60), 90);
        byte[] png = Encode(new PngBitmapEncoder(), Gradient(40, 40));

        var made = PdfFromPictures.Create([jpeg, png, [1, 2, 3]], Codec);

        Assert.Equal(2, made.Pages);
        Assert.Equal([2], made.Unreadable);
        using var reopened = PdfDocument.Open(made.Bytes);
        Assert.Equal(2, reopened.Pages.Count);
    }

    [Fact]
    public void APictureWithTooManyPixelsIsLeftUnreadAndNotAnException()
    {
        const int side = 16384;
        var bitmap = BitmapSource.Create(side, side, 96, 96, PixelFormats.BlackWhite, null, new byte[side / 8 * side], side / 8);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        Assert.Empty(Codec.DecodeFile(stream.ToArray()) ?? []);
    }

    [Fact]
    public void AFrameWithTooManyPixelsDoesNotTakeTheOtherFramesWithIt()
    {
        const int side = 16384;
        BitmapSource Blank(int size) => BitmapSource.Create(size, size, 96, 96, PixelFormats.BlackWhite, null, new byte[(size + 7) / 8 * size], (size + 7) / 8);
        var encoder = new TiffBitmapEncoder();
        foreach (int size in new[] { 8, side, 16 }) encoder.Frames.Add(BitmapFrame.Create(Blank(size)));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        var frames = Codec.DecodeFile(stream.ToArray());
        Assert.Equal([8, 16], frames!.Select(f => f.Width));
    }
}
