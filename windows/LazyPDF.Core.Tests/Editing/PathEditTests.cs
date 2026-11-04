using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PathEditTests
{
    private const string Content =
        "1 0 0 rg 0 0 1 RG 3 w 100 100 200 100 re B\n" +
        "q 0 1 0 rg 300 300 m 400 300 l 400 400 l h f Q\n" +
        "q 0 0 50 50 re W n 0 g 5 w 10 10 m 90 90 l S Q";

    private static (PdfEditSession, PageEditor) Open()
    {
        var session = EditKit.Session(Content);
        return (session, new PageEditor(session, 0));
    }

    private static List<PathObject> Paths(PageEditor editor) => [.. editor.Objects.OfType<PathObject>()];

    [Fact]
    public void PathsAreModelledWithTheirPaint()
    {
        var (_, editor) = Open();
        var paths = Paths(editor);
        Assert.Equal(3, paths.Count);
        Assert.True(paths[0].Fill && paths[0].Stroke);
        Assert.Equal(new RgbColor(255, 0, 0), paths[0].FillColor);
        Assert.Equal(new RgbColor(0, 0, 255), paths[0].StrokeColor);
        Assert.Equal(3, paths[0].LineWidth);
        Assert.Equal(new PdfRect(98.5, 98.5, 301.5, 201.5), paths[0].Bounds);
        Assert.False(paths[1].Stroke);
        Assert.Equal(new RgbColor(0, 255, 0), paths[1].FillColor);
        Assert.Equal(5, paths[2].LineWidth);
    }

    [Fact]
    public void MoveAndScaleLeaveTheCoordinatesAlone()
    {
        var (session, editor) = Open();
        Assert.True(editor.Move([Paths(editor)[0]], 50, 25).Done);
        var moved = EditPaint.Paths(session)[0].Path;
        Assert.Equal(new PdfRect(150, 125, 350, 225), moved.Bounds);
        Assert.Contains("100 100 200 100 re B", EditKit.Latin(session));

        editor.Refresh();
        Assert.True(editor.Resize([Paths(editor)[0]], new PdfRect(100, 100, 200, 150)).Done);
        var scaled = EditPaint.Paths(session)[0].Path;
        var ink = new PageEditor(session, 0).Objects.OfType<PathObject>().First().Bounds;
        Assert.Equal(100, ink.Left, 0);
        Assert.Equal(200, ink.Right, 0);
        Assert.Equal(100, ink.Bottom, 0);
        Assert.Equal(150, ink.Top, 0);
        Assert.True(scaled.Bounds.Width < 100);
    }

    [Fact]
    public void RecolourAndLineWidthApplyToThatPathOnly()
    {
        var (session, editor) = Open();
        var result = editor.SetPathStyle([Paths(editor)[0]], fill: new RgbColor(255, 255, 0), stroke: new RgbColor(0, 0, 0), lineWidth: 8);
        Assert.True(result.Done);
        var seen = EditPaint.Paths(session);
        Assert.Equal((new RgbColor(255, 255, 0), new RgbColor(0, 0, 0), 8), (seen[0].Fill, seen[0].Stroke, seen[0].LineWidth));
        Assert.Equal(new RgbColor(0, 255, 0), seen[1].Fill);
        Assert.Equal(5, seen[2].LineWidth);
    }

    [Fact]
    public void ADeletedPathIsGoneAndThePageAroundItKeepsItsBytes()
    {
        var (session, editor) = Open();
        Assert.True(editor.Delete([Paths(editor)[1]]).Done);
        Assert.Equal(2, EditPaint.Paths(session).Count);
        string text = EditKit.Latin(session);
        Assert.StartsWith("1 0 0 rg 0 0 1 RG 3 w 100 100 200 100 re B\nq 0 1 0 rg ", text);
        Assert.EndsWith(" Q\nq 0 0 50 50 re W n 0 g 5 w 10 10 m 90 90 l S Q", text);
    }

    [Fact]
    public void APathThatClipsStaysAClipWhenItIsDeletedAndCannotBeMoved()
    {
        var session = EditKit.Session("q 0 0 100 100 re W f 0 g 10 10 m 90 90 l S Q");
        var editor = new PageEditor(session, 0);
        var clipping = Paths(editor)[0];
        Assert.True(clipping.Clips);
        var moved = editor.Move([clipping], 5, 5);
        Assert.False(moved.Done);
        Assert.Equal(EditingText.ClipPath, moved.Skipped[0].Reason);
        Assert.True(editor.Delete([clipping]).Done);
        Assert.Contains("0 0 100 100 re W n", EditKit.Latin(session));
        Assert.Single(EditPaint.Paths(session));
    }

    [Fact]
    public void NewShapesArePaintedWhereAsked()
    {
        var session = EditKit.Session("5 0 0 5 0 0 cm 1 0 0 rg 0 0 10 10 re f");
        var editor = new PageEditor(session, 0);
        Assert.True(editor.AddLine(10, 10, 110, 60, new ShapeStyle(new RgbColor(0, 0, 255), Width: 2)).Done);
        Assert.True(editor.AddRectangle(new PdfRect(200, 200, 260, 240), new ShapeStyle(Fill: new RgbColor(0, 128, 0), Opacity: 0.5)).Done);
        Assert.True(editor.AddEllipse(new PdfRect(300, 300, 400, 340), new ShapeStyle(new RgbColor(0, 0, 0), new RgbColor(255, 255, 0))).Done);
        var seen = EditPaint.Paths(session);
        Assert.Equal(4, seen.Count);
        Assert.Equal(new PdfRect(10, 10, 110, 60), seen[1].Path.Bounds);
        Assert.Equal(2, seen[1].LineWidth);
        Assert.Equal(new RgbColor(0, 0, 255), seen[1].Stroke);
        Assert.Equal(new PdfRect(200, 200, 260, 240), seen[2].Path.Bounds);
        Assert.Equal(0.5, seen[2].Alpha, 3);
        Assert.Equal(new RgbColor(0, 128, 0), seen[2].Fill);
        Assert.Equal(300, seen[3].Path.Bounds.Left, 1);
        Assert.Equal(400, seen[3].Path.Bounds.Right, 1);
        Assert.Equal(340, seen[3].Path.Bounds.Top, 1);
        Assert.True(seen[3].Path.Fill && seen[3].Path.Stroke);
        Assert.Equal("Add ellipse", session.UndoLabel);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(session.Current.ToArray());
        Assert.Equal(4, pig.GetPage(1).Paths.Count);
    }

    [Fact]
    public void ManyObjectsMoveInOneStep()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (some text) Tj ET\n" + Content);
        var editor = new PageEditor(session, 0);
        var all = editor.Objects.ToList();
        var before = EditKit.Glyphs(session);
        var paths = EditPaint.Paths(session).Select(p => p.Path.Bounds).ToList();
        var result = editor.Move(all, 7, -3);
        Assert.Equal(all.Count, result.Changed);
        Assert.Equal("Move", session.UndoLabel);
        var glyphs = EditKit.Glyphs(session);
        for (int i = 0; i < glyphs.Count; i++)
        {
            Assert.Equal(before[i].X + 7, glyphs[i].X, 2);
            Assert.Equal(before[i].Y - 3, glyphs[i].Y, 2);
        }
        var moved = EditPaint.Paths(session).Select(p => p.Path.Bounds).ToList();
        for (int i = 0; i < moved.Count; i++) Assert.Equal(paths[i].Left + 7, moved[i].Left, 2);
        Assert.True(session.Undo());
        Assert.Equal(before, EditKit.Glyphs(session));
        Assert.False(session.CanUndo);
    }

    [Fact]
    public void AStaleObjectIsRefused()
    {
        var (_, editor) = Open();
        var old = Paths(editor)[0];
        editor.Move([old], 1, 1);
        Assert.Throws<ArgumentException>(() => editor.Move([old], 1, 1));
    }
}
