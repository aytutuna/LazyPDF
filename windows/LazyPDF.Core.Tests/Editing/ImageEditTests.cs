using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ImageEditTests
{
    private static (PdfEditSession Session, PageEditor Editor) Open() => Open(EditPaint.Pictures());

    private static (PdfEditSession, PageEditor) Open(PdfEditSession session) => (session, new PageEditor(session, 0, new EditArialSource()));

    private static ImageObject First(PageEditor editor) => editor.Objects.OfType<ImageObject>().First();

    private static PdfMatrix Round(PdfMatrix m) => new(Math.Round(m.A, 3), Math.Round(m.B, 3), Math.Round(m.C, 3), Math.Round(m.D, 3), Math.Round(m.E, 3), Math.Round(m.F, 3));

    [Fact]
    public void ImagesAreInTheModelWithTheirPlacement()
    {
        var (_, editor) = Open();
        var images = editor.Objects.OfType<ImageObject>().ToList();
        Assert.Equal(2, images.Count);
        Assert.Equal("Im1", images[0].Name);
        Assert.Equal((8, 6), (images[0].Width, images[0].Height));
        Assert.Equal(new PdfMatrix(100, 0, 0, 50, 100, 600), images[0].Placement);
        Assert.Equal(new PdfRect(100, 600, 200, 650), images[0].Bounds);
        Assert.Equal(1, images[0].Opacity);
    }

    [Fact]
    public void MoveWrapsThePaintWithoutTouchingItsCoordinates()
    {
        var (session, editor) = Open();
        string before = EditKit.Latin(session);
        var result = editor.Move([First(editor)], 25, -40);
        Assert.True(result.Done);
        var images = EditPaint.Images(session);
        Assert.Equal(125, images[0].Matrix.E, 3);
        Assert.Equal(560, images[0].Matrix.F, 3);
        Assert.Equal(100, images[0].Matrix.A, 3);
        Assert.Equal(new PdfMatrix(80, 0, 0, 80, 300, 600), images[1].Matrix);
        string after = EditKit.Latin(session);
        Assert.Contains("q 100 0 0 50 100 600 cm", after);
        Assert.Contains("/Im1 Do", after);
        Assert.NotEqual(before, after);
    }

    [Fact]
    public void ResizeRotateAndFlip()
    {
        var (session, editor) = Open();
        Assert.True(editor.Resize([First(editor)], new PdfRect(100, 600, 300, 700)).Done);
        var m = EditPaint.Images(session)[0].Matrix;
        Assert.Equal(new PdfMatrix(200, 0, 0, 100, 100, 600), Round(m));

        editor.Refresh();
        Assert.True(editor.Rotate([First(editor)], 90).Done);
        m = EditPaint.Images(session)[0].Matrix;
        Assert.Equal(0, m.A, 3);
        Assert.Equal(200, m.B, 3);
        Assert.Equal(-100, m.C, 3);

        editor.Refresh();
        var before = EditPaint.Images(session)[0].Matrix;
        Assert.True(editor.Flip([First(editor)], horizontal: true).Done);
        var mirrored = EditPaint.Images(session)[0].Matrix;
        Assert.Equal(-before.A, mirrored.A, 3);
        Assert.Equal(before.B, mirrored.B, 3);
    }

    [Fact]
    public void ACropClipsThePaint()
    {
        var (session, editor) = Open();
        Assert.True(editor.Crop(First(editor), new PdfRect(120, 610, 170, 640)).Done);
        var seen = EditPaint.Images(session);
        Assert.Equal(new PdfRect(120, 610, 170, 640), seen[0].Clip);
        Assert.Equal(new PdfMatrix(100, 0, 0, 50, 100, 600), seen[0].Matrix);
        Assert.Equal(new PdfRect(0, 0, 600, 800), seen[1].Clip);
    }

    [Fact]
    public void ACropOutsideThePictureIsRefused()
    {
        var (session, editor) = Open();
        var result = editor.Crop(First(editor), new PdfRect(400, 10, 450, 40));
        Assert.False(result.Done);
        Assert.False(session.CanUndo);
    }

    [Fact]
    public void ReplacingKeepsThePlaceAndFitsTheProportions()
    {
        var (session, editor) = Open();
        // The second picture is square at 80 by 80; the JPEG is 8 by 6, so it fills the width and is centred.
        var second = editor.Objects.OfType<ImageObject>().Last();
        var result = editor.ReplaceImage(second, EditPaint.Jpeg());
        Assert.True(result.Done);
        var seen = EditPaint.Images(session);
        Assert.Equal((8, 6), (seen[1].Width, seen[1].Height));
        Assert.Equal(60, seen[1].Matrix.D, 3);
        Assert.Equal(80, seen[1].Matrix.A, 3);
        Assert.Equal(610, seen[1].Matrix.F, 3);
        Assert.Equal(0, seen.Count(s => s.Width == 2));
    }

    [Fact]
    public void ReplacingWithAPictureFileNeedsTheCodec()
    {
        var (session, editor) = Open();
        var result = editor.ReplaceImage(First(editor), [0x89, 0x50, 0x4E, 0x47]);
        Assert.False(result.Done);
        Assert.Equal(EditingText.NoImage, Assert.Single(result.Skipped).Reason);
        Assert.False(session.CanUndo);
    }

    [Fact]
    public void ReplacingThroughTheCodecEmbedsThePixels()
    {
        var session = EditPaint.Pictures();
        var editor = new PageEditor(session, 0, null, new FakeCodec());
        Assert.True(editor.ReplaceImage(First(editor), [1, 2, 3], fit: false).Done);
        var seen = EditPaint.Images(session);
        Assert.Equal((2, 2), (seen[0].Width, seen[0].Height));
        Assert.Equal(new PdfMatrix(100, 0, 0, 50, 100, 600), seen[0].Matrix);
    }

    private sealed class FakeCodec : IImageCodec
    {
        public PdfRgbaImage? Decode(byte[] data, string codec) => null;
        public IReadOnlyList<PdfRgbaImage>? DecodeFile(byte[] file) => [new PdfRgbaImage(2, 2, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 9, 9, 9, 128])];
        public byte[] EncodeJpeg(PdfRgbaImage image, int quality) => [];
    }

    private static void AssertDone(ObjectEditResult r) => Assert.True(r.Done, string.Join(", ", r.Skipped.Select(s => s.Reason)));

    [Fact]
    public void DeleteOpacityAndOrder()
    {
        var (session, editor) = Open();
        Assert.True(editor.SetOpacity([First(editor)], 0.4).Done);
        Assert.Equal(0.4, EditPaint.Images(session)[0].Alpha, 3);
        Assert.Equal(1, EditPaint.Images(session)[1].Alpha, 3);

        editor.Refresh();
        AssertDone(editor.Order(editor.Objects.OfType<ImageObject>().Last(), OrderMove.Backward));
        Assert.Equal(2, EditPaint.Images(session)[0].Width);

        editor.Refresh();
        AssertDone(editor.Order(editor.Objects.OfType<ImageObject>().Last(), OrderMove.Back));
        Assert.Equal(8, EditPaint.Images(session)[0].Width);

        editor.Refresh();
        AssertDone(editor.Order(editor.Objects.OfType<ImageObject>().First(), OrderMove.Front));
        Assert.Equal(8, EditPaint.Images(session)[1].Width);

        editor.Refresh();
        var again = editor.Order(editor.Objects.OfType<ImageObject>().Last(), OrderMove.Forward);
        Assert.False(again.Done);
        Assert.Equal(EditingText.AlreadyThere, again.Skipped[0].Reason);

        editor.Refresh();
        Assert.True(editor.Delete([First(editor)]).Done);
        Assert.Single(EditPaint.Images(session));
    }

    [Fact]
    public void ExtractGivesTheJpegAsStoredAndOtherPicturesAsPng()
    {
        var (_, editor) = Open();
        var jpeg = editor.ExtractImage(First(editor))!;
        Assert.Equal("jpg", jpeg.Extension);
        Assert.Equal(EditPaint.Jpeg(), jpeg.Data);
        var png = editor.ExtractImage(editor.Objects.OfType<ImageObject>().Last())!;
        Assert.Equal("png", png.Extension);
        Assert.Equal([0x89, 0x50, 0x4E, 0x47], png.Data[..4]);
        Assert.Equal(2, png.Data[19]);
        Assert.Equal(2, png.Data[23]);
    }

    [Fact]
    public void EditsReopenInPdfPigAndUndoOneByOne()
    {
        var (session, editor) = Open();
        editor.Move([First(editor)], 10, 10);
        editor.Refresh();
        editor.Rotate([First(editor)], 30);
        Assert.True(session.Undo());
        Assert.Equal(110, EditPaint.Images(session)[0].Matrix.E, 3);
        Assert.True(session.Undo());
        Assert.Equal(100, EditPaint.Images(session)[0].Matrix.E, 3);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(session.Current.ToArray());
        Assert.Equal(2, pig.GetPage(1).GetImages().Count());
    }
}
