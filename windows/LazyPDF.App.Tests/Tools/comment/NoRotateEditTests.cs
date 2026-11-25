using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Comment;

// A text box made on a turned page keeps reading upright in the file (NoRotate); its editor opens where the box is drawn.
[Collection("Application")]
public sealed class NoRotateEditTests
{
    private static readonly Point[] Drag = [new(60, 80), new(260, 140)];

    [Theory]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public Task AnExistingBoxOpensItsEditorWhereItIsDrawnAndIsWrittenBackUnchanged(int degrees) => Sta.Run(() =>
    {
        using var f = new CommentFixture();
        f.Document.Pages[0].Dictionary["Rotate"] = new PdfNumber(degrees);
        var made = f.Marker.Add(MarkTool.TextBox, 0, Drag, MarkStyle.Default, "Hello");
        var mark = f.Marks().Single(m => m.Reference?.Number == made.Reference?.Number);
        Assert.True(mark.Flags.HasFlag(AnnotationFlags.NoRotate));
        var area = f.Marker.BoxOf(mark);
        var overlay = new PageOverlay(0, new Size(f.Geometry.Width, f.Geometry.Height));
        string? typed = null;

        var editor = LazyPDF.App.Tools.Comment.TextEditor.Open(overlay, area, 12, mark.Contents ?? "", 0, text => typed = text);

        var box = Assert.IsType<TextBox>(Assert.Single(overlay.Children));
        Assert.Equal(60, Canvas.GetLeft(box), 0.5);
        Assert.Equal(80, Canvas.GetTop(box), 0.5);
        Assert.Equal(200, box.Width, 0.5);
        editor.Finish();
        Assert.Equal("Hello", typed);

        var again = f.Marker.SetText(mark, typed!);

        var read = f.Marks().Single(m => m.Reference?.Number == made.Reference?.Number);
        Assert.Equal(mark.Rect, read.Rect);
        Assert.True(read.Flags.HasFlag(AnnotationFlags.NoRotate));
        Assert.Equal("Hello", again.Contents);
        var after = f.Marker.BoxOf(read);
        Assert.Equal(area.X, after.X, 0.5);
        Assert.Equal(area.Y, after.Y, 0.5);
        Assert.Equal(area.Width, after.Width, 0.5);
        Assert.Equal(area.Height, after.Height, 0.5);
        return Task.CompletedTask;
    });
}
