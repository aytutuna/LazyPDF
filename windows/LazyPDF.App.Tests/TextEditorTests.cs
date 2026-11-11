using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Viewer;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class TextEditorTests
{
    [Fact]
    public Task ABoxOpenedAtThePageEdgeStaysInsideIt() => Sta.Run(() =>
    {
        var overlay = new PageOverlay(0, new Size(200, 200));

        TextEditor.Open(overlay, new Rect(190, 190, 10, 10), 12, "", 0, _ => { });

        var box = Assert.IsType<TextBox>(Assert.Single(overlay.Children));
        Assert.True(Canvas.GetLeft(box) + box.Width <= 200);
        Assert.True(Canvas.GetTop(box) + box.MinHeight <= 200);
        Assert.True(box.MaxHeight <= 200 - Canvas.GetTop(box) || box.MaxHeight == box.MinHeight);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ALargeFontAtThePageBottomKeepsRoomForALine() => Sta.Run(() =>
    {
        var overlay = new PageOverlay(0, new Size(400, 600));

        TextEditor.Open(overlay, new Rect(10, 590, 100, 10), 72, "", 0, _ => { });

        var box = Assert.IsType<TextBox>(Assert.Single(overlay.Children));
        Assert.True(box.MinHeight >= 72);
        Assert.True(Canvas.GetTop(box) + box.MinHeight <= 600);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ARotatedViewTurnsTheBoxBack() => Sta.Run(() =>
    {
        var overlay = new PageOverlay(0, new Size(200, 200));

        var editor = TextEditor.Open(overlay, new Rect(10, 10, 100, 20), 12, "", 90, _ => { });

        var box = Assert.IsType<TextBox>(Assert.Single(overlay.Children));
        Assert.Equal(-90, Assert.IsType<RotateTransform>(box.RenderTransform).Angle);
        editor.Upright(0);
        Assert.Null(box.RenderTransform);
        return Task.CompletedTask;
    });
}
