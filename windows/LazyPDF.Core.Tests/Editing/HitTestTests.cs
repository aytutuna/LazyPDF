using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class HitTestTests
{
    private static PageEditor Open(out PdfEditSession session)
    {
        session = EditKit.Session(
            "0.8 g 50 50 200 100 re f\n" +
            "BT /F1 12 Tf 60 100 Td 0 g (Label) Tj ET\n" +
            "q 40 40 -40 40 400 400 cm 0 0 1 rg 0 0 1 1 re f Q\n" +
            "1 0 0 RG 3 w 300 100 m 500 100 l S\n" +
            "0 1 0 rg 450 200 m 550 200 l 500 300 l h f");
        return new PageEditor(session, 0);
    }

    [Fact]
    public void TheTopmostObjectUnderThePointIsFound()
    {
        var editor = Open(out _);
        Assert.Equal(5, editor.Objects.Count);
        Assert.IsType<TextObject>(editor.HitTest(70, 103));
        // The grey box is under the text; away from the text the box answers.
        Assert.Equal(0, editor.HitTest(200, 70)!.Id);
        Assert.IsType<PathObject>(editor.HitTest(200, 70));
        Assert.Null(editor.HitTest(20, 20));
    }

    [Fact]
    public void ARotatedFillIsHitInsideTheTurnedSquareOnly()
    {
        var editor = Open(out _);
        // The square is turned 45 degrees: its corners are at (400,400), (440,440), (400,480), (360,440).
        Assert.NotNull(editor.HitTest(400, 440));
        Assert.Null(editor.HitTest(365, 405));
    }

    [Fact]
    public void AStrokeIsHitNearItsLineAndATriangleInsideIt()
    {
        var editor = Open(out _);
        Assert.IsType<PathObject>(editor.HitTest(400, 101));
        Assert.Null(editor.HitTest(400, 110));
        Assert.IsType<PathObject>(editor.HitTest(500, 230));
        Assert.Null(editor.HitTest(460, 280));
    }

    [Fact]
    public void ARectangleSelectsWhatTouchesOrWhatLiesInside()
    {
        var editor = Open(out _);
        var rect = new PdfRect(40, 40, 260, 160);
        Assert.Equal(2, editor.Select(rect).Count);
        Assert.Equal(2, editor.Select(rect, contained: true).Count);
        Assert.Single(editor.Select(new PdfRect(0, 0, 100, 100), contained: false), o => o is TextObject);
        Assert.Empty(editor.Select(new PdfRect(0, 0, 100, 100), contained: true));
    }

    [Fact]
    public void ObjectsKnowTheirKindFormAndBounds()
    {
        var editor = Open(out _);
        Assert.Equal([PageObjectKind.Path, PageObjectKind.Text, PageObjectKind.Path, PageObjectKind.Path, PageObjectKind.Path], editor.Objects.Select(o => o.Kind));
        Assert.All(editor.Objects, o => Assert.Empty(o.Forms));
        var text = (TextObject)editor.Objects[1];
        Assert.Equal("Label", text.Text);
        Assert.Equal(12, text.Size, 2);
        Assert.Equal("Helvetica", text.Font!.Name);
        Assert.Equal(new RgbColor(0, 0, 0), text.Color);
        Assert.Equal(60, text.Bounds.Left, 1);
    }

    [Fact]
    public void AnEditorWhoseSessionLostItsPageThrowsOutOfRange()
    {
        Open(out var session);
        PageOperations.InsertBlank(session.Document, 1, 612, 792);
        Assert.True(session.Commit("Insert page"));
        var last = new PageEditor(session, 1);
        Assert.Empty(last.Objects);
        Assert.True(session.Undo());
        Assert.ThrowsAny<ArgumentException>(() => last.Objects);
        Assert.ThrowsAny<ArgumentException>(() => last.Text);
        Assert.ThrowsAny<ArgumentException>(() => last.HitTest(10, 10));
        Assert.ThrowsAny<ArgumentException>(() => last.Select(new PdfRect(0, 0, 100, 100)));
        Assert.ThrowsAny<ArgumentException>(() => last.AddRectangle(new PdfRect(10, 10, 50, 50), new ShapeStyle(new RgbColor(0, 0, 0))));
        Assert.ThrowsAny<ArgumentException>(() => new PageEditor(session, 1));
    }
}
