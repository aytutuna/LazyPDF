using System.Windows;
using System.Windows.Controls;
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

        TextEditor.Open(overlay, new Rect(190, 190, 10, 10), 12, "", _ => { });

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

        TextEditor.Open(overlay, new Rect(10, 590, 100, 10), 72, "", _ => { });

        var box = Assert.IsType<TextBox>(Assert.Single(overlay.Children));
        Assert.True(box.MinHeight >= 72);
        Assert.True(Canvas.GetTop(box) + box.MinHeight <= 600);
        return Task.CompletedTask;
    });
}
