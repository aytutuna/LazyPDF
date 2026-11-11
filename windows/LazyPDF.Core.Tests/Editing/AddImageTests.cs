using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A picture added to a page: centred in the box it was given and upright on the page as it is shown.
public class AddImageTests
{
    private sealed class SquareCodec : IImageCodec
    {
        public PdfRgbaImage? Decode(byte[] data, string codec) => null;
        public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file) => file.Length == 0 ? null : [new PdfRgbaImage(2, 2, new byte[16])];
        public byte[] EncodeJpeg(PdfRgbaImage image, int quality) => [];
    }

    private sealed class HugeCodec : IImageCodec
    {
        public PdfRgbaImage? Decode(byte[] data, string codec) => null;
        public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file) => [new PdfRgbaImage(12000, 12000, new byte[16])];
        public byte[] EncodeJpeg(PdfRgbaImage image, int quality) => [];
    }

    // Decodes any file as 4 by 2 gray pixels 10 to 17, row by row.
    private sealed class RowsCodec : IImageCodec
    {
        public PdfRgbaImage? Decode(byte[] data, string codec) => null;

        public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file)
        {
            var rgba = new byte[32];
            for (int i = 0; i < 8; i++) (rgba[4 * i], rgba[4 * i + 1], rgba[4 * i + 2], rgba[4 * i + 3]) = ((byte)(10 + i), (byte)(10 + i), (byte)(10 + i), 255);
            return [new PdfRgbaImage(4, 2, rgba)];
        }

        public byte[] EncodeJpeg(PdfRgbaImage image, int quality) => [];
    }

    // The sample JPEG with an Exif block after its JFIF header that carries the given orientation.
    private static byte[] Oriented(int orientation)
    {
        var jpeg = ExportKit.Jpeg;
        byte[] exif = [0xFF, 0xE1, 0, 34, (byte)'E', (byte)'x', (byte)'i', (byte)'f', 0, 0, (byte)'M', (byte)'M', 0, 42, 0, 0, 0, 8,
            0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, (byte)orientation, 0, 0, 0, 0, 0, 0];
        int at = 4 + (jpeg[4] << 8 | jpeg[5]);
        return [.. jpeg[..at], .. exif, .. jpeg[at..]];
    }

    private static (PdfImage Image, byte[] Gray) Added(int orientation)
    {
        var document = ExportKit.Open("");
        var image = PdfImageWriter.AddPicture(document, Oriented(orientation), new RowsCodec());
        Assert.NotNull(image);
        var stream = (PdfStream)document.Resolve(image.Reference)!;
        return (image, [.. document.Data(stream).Where((_, i) => i % 3 == 0)]);
    }

    [Fact]
    public void AJpegTurnedBySixIsStoredUprightAndSwapsItsSides()
    {
        var (image, gray) = Added(6);

        Assert.Equal((2, 4), (image.Width, image.Height));
        Assert.Equal(new byte[] { 14, 10, 15, 11, 16, 12, 17, 13 }, gray);
    }

    [Fact]
    public void AJpegTurnedByThreeKeepsItsSizeAndReversesRowsAndColumns()
    {
        var (image, gray) = Added(3);

        Assert.Equal((4, 2), (image.Width, image.Height));
        Assert.Equal(new byte[] { 17, 16, 15, 14, 13, 12, 11, 10 }, gray);
    }

    [Fact]
    public void AJpegWithoutATurnKeepsItsBytes()
    {
        var document = ExportKit.Open("");
        var file = Oriented(1);

        var image = PdfImageWriter.AddPicture(document, file, new RowsCodec());

        var stream = (PdfStream)document.Resolve(image!.Reference)!;
        Assert.Equal("DCTDecode", ((PdfName)stream.Dictionary["Filter"]!).Value);
        Assert.Equal(file, document.RawData(stream));
    }

    [Fact]
    public void ATurnedJpegOnAPageIsAddedUpright()
    {
        var session = EditKit.Session("q 1 0 0 rg 0 0 50 50 re f Q");
        var editor = new PageEditor(session, 0, null, new RowsCodec());

        Assert.True(editor.AddImage(new PdfRect(100, 500, 300, 600), Oriented(8)).Done);

        var image = Assert.Single(EditPaint.Images(session));
        Assert.Equal((2, 4), (image.Width, image.Height));
    }

    [Fact]
    public void ADecodedPictureThatDoesNotFitIsRefusedNotThrown()
    {
        var session = EditKit.Session("q 1 0 0 rg 0 0 50 50 re f Q");
        var editor = new PageEditor(session, 0, null, new HugeCodec());

        var result = editor.AddImage(new PdfRect(100, 500, 300, 600), [1]);

        Assert.False(result.Done);
        Assert.Empty(EditPaint.Images(session));
    }

    [Fact]
    public void ThePictureKeepsItsShapeAndSitsInTheMiddleOfTheBox()
    {
        var session = EditKit.Session("q 1 0 0 rg 0 0 50 50 re f Q");
        var editor = new PageEditor(session, 0, null, new SquareCodec());

        var result = editor.AddImage(new PdfRect(100, 500, 300, 600), [1]);

        Assert.True(result.Done);
        var image = Assert.Single(EditPaint.Images(session));
        Assert.Equal(new PdfMatrix(100, 0, 0, 100, 150, 500), image.Matrix);
    }

    [Fact]
    public void OnATurnedPageThePictureIsStillUprightInTheBox()
    {
        var session = EditKit.Session("q 1 0 0 rg 0 0 50 50 re f Q", "/Rotate 90");
        var editor = new PageEditor(session, 0, null, new SquareCodec());

        Assert.True(editor.AddImage(new PdfRect(100, 500, 300, 600), [1]).Done);

        var bounds = editor.Objects.OfType<ImageObject>().Single().Bounds;
        Assert.Equal(100, bounds.Width, 1);
        Assert.Equal(100, bounds.Height, 1);
        Assert.Equal(200, (bounds.Left + bounds.Right) / 2, 1);
        Assert.Equal(550, (bounds.Bottom + bounds.Top) / 2, 1);
    }

    [Fact]
    public void BytesNoCodecReadAreRefusedAndNothingIsCommitted()
    {
        var session = EditKit.Session("q 1 0 0 rg 0 0 50 50 re f Q");
        var editor = new PageEditor(session, 0, null, new SquareCodec());

        var result = editor.AddImage(new PdfRect(100, 500, 300, 600), []);

        Assert.False(result.Done);
        Assert.Equal(EditingText.NoImage, result.Skipped[0].Reason);
        Assert.False(session.CanUndo);
    }

    [Fact]
    public void AnEmptyBoxIsRefused()
    {
        var session = EditKit.Session("q 1 0 0 rg 0 0 50 50 re f Q");

        var result = new PageEditor(session, 0, null, new SquareCodec()).AddImage(new PdfRect(100, 500, 100, 600), [1]);

        Assert.False(result.Done);
        Assert.False(session.CanUndo);
    }
}
