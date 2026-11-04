using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class PdfImageWriterTests
{
    private static readonly byte[] Jpeg = Convert.FromBase64String(StampKit.SampleJpeg);

    // SOI, an optional Adobe APP14, then a frame header of the given marker and no scan.
    private static byte[] Header(byte marker, int components, bool adobe = false, int width = 40, int height = 30)
    {
        var bytes = new List<byte> { 0xFF, 0xD8 };
        if (adobe) bytes.AddRange([0xFF, 0xEE, 0, 14, (byte)'A', (byte)'d', (byte)'o', (byte)'b', (byte)'e', 0, 100, 0, 0, 0, 0, 2]);
        int length = 8 + 3 * components;
        bytes.AddRange([0xFF, marker, 0, (byte)length, 8, (byte)(height >> 8), (byte)height, (byte)(width >> 8), (byte)width, (byte)components]);
        for (int i = 0; i < components; i++) bytes.AddRange([(byte)(i + 1), 0x11, 0]);
        bytes.AddRange([0xFF, 0xD9]);
        return [.. bytes];
    }

    private static PdfStream Stream(PdfDocument document, PdfImage image) => (PdfStream)document.Resolve(image.Reference)!;

    [Fact]
    public void AJpegGoesInAsItIsWithItsSize()
    {
        var document = StampKit.Doc(1);
        var image = PdfImageWriter.AddJpeg(document, Jpeg)!;
        Assert.Equal((8, 6), (image.Width, image.Height));
        var stream = Stream(document, image);
        Assert.Equal("DCTDecode", document.Name(stream.Dictionary, "Filter"));
        Assert.Equal("DeviceRGB", document.Name(stream.Dictionary, "ColorSpace"));
        Assert.Equal(8, document.Integer(stream.Dictionary, "Width"));
        Assert.Same(Jpeg, stream.Data);
    }

    [Fact]
    public void GrayAndProgressiveFramesAreRead()
    {
        var document = StampKit.Doc(1);
        var gray = PdfImageWriter.AddJpeg(document, Header(0xC2, 1))!;
        Assert.Equal((40, 30), (gray.Width, gray.Height));
        Assert.Equal("DeviceGray", document.Name(Stream(document, gray).Dictionary, "ColorSpace"));
    }

    [Fact]
    public void AnAdobeCmykJpegIsInvertedByDecode()
    {
        var document = StampKit.Doc(1);
        var image = PdfImageWriter.AddJpeg(document, Header(0xC0, 4, adobe: true))!;
        var dictionary = Stream(document, image).Dictionary;
        Assert.Equal("DeviceCMYK", document.Name(dictionary, "ColorSpace"));
        Assert.Equal(8, document.Array(dictionary, "Decode")!.Items.Count);
    }

    [Fact]
    public void WhatIsNotAReadableJpegGivesNull()
    {
        var document = StampKit.Doc(1);
        Assert.Null(PdfImageWriter.AddJpeg(document, []));
        Assert.Null(PdfImageWriter.AddJpeg(document, [0xFF, 0xD8]));
        Assert.Null(PdfImageWriter.AddJpeg(document, "not a picture at all"u8.ToArray()));
        Assert.Null(PdfImageWriter.AddJpeg(document, Jpeg[..40]));
        Assert.Null(PdfImageWriter.AddJpeg(document, Header(0xC0, 2)));
        Assert.Null(PdfImageWriter.AddJpeg(document, Header(0xC0, 3, width: 0)));
    }

    [Fact]
    public void ARunOfFillBytesBeforeAMarkerIsSkipped()
    {
        byte[] frame = Header(0xC0, 3);
        byte[] padded = [.. frame[..2], 0xFF, 0xFF, 0xFF, .. frame[2..]];
        Assert.True(PdfImageWriter.TryReadJpegHeader(padded, out int width, out int height, out int components));
        Assert.Equal((40, 30, 3), (width, height, components));
    }

    [Fact]
    public void OpaquePixelsHaveNoMask()
    {
        var document = StampKit.Doc(1);
        var image = PdfImageWriter.AddRgba(document, 2, 1, [10, 20, 30, 255, 40, 50, 60, 255]);
        var stream = Stream(document, image);
        Assert.Equal((2, 1), (image.Width, image.Height));
        Assert.Null(stream.Dictionary["SMask"]);
        Assert.Equal([10, 20, 30, 40, 50, 60], document.Data(stream));
    }

    [Fact]
    public void TranslucentPixelsGetAnSMaskAndReopen()
    {
        var document = StampKit.Doc(1);
        var image = PdfImageWriter.AddRgba(document, 2, 1, [10, 20, 30, 0, 40, 50, 60, 200]);
        var mask = document.Stream(Stream(document, image).Dictionary, "SMask")!;
        Assert.Equal([0, 200], document.Data(mask));
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Image = image });
        using var pig = PigDocument.Open(StampKit.Rewrite(document));
        Assert.Single(pig.GetPage(1).GetImages());
    }

    [Fact]
    public void PixelsThatDoNotFitTheSizeAreRefused()
    {
        var document = StampKit.Doc(1);
        Assert.Throws<ArgumentException>(() => PdfImageWriter.AddRgba(document, 2, 2, new byte[12]));
        Assert.Throws<ArgumentException>(() => PdfImageWriter.AddRgba(document, 0, 1, []));
    }
}
