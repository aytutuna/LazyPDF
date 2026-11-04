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
