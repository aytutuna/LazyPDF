using System.Windows;
using LazyPDF.App.Tools.Redact;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class RedactBoxEditorTests
{
    private static readonly Size Page = new(200, 100);
    private static readonly Rect Box = new(50, 40, 60, 30);

    [Theory]
    [InlineData(RedactBoxEditor.Handle.Body, 60, 45, 60, 30)]
    [InlineData(RedactBoxEditor.Handle.TopLeft, 60, 45, 50, 25)]
    [InlineData(RedactBoxEditor.Handle.Top, 50, 45, 60, 25)]
    [InlineData(RedactBoxEditor.Handle.TopRight, 50, 45, 70, 25)]
    [InlineData(RedactBoxEditor.Handle.Right, 50, 40, 70, 30)]
    [InlineData(RedactBoxEditor.Handle.BottomRight, 50, 40, 70, 35)]
    [InlineData(RedactBoxEditor.Handle.Bottom, 50, 40, 60, 35)]
    [InlineData(RedactBoxEditor.Handle.BottomLeft, 60, 40, 50, 35)]
    [InlineData(RedactBoxEditor.Handle.Left, 60, 40, 50, 30)]
    public void EachHandleMovesItsOwnEdges(RedactBoxEditor.Handle handle, double x, double y, double width, double height)
    {
        var box = RedactBoxEditor.Drag(Box, handle, new Vector(10, 5), Page);

        Assert.Equal(new Rect(x, y, width, height), box);
    }

    [Fact]
    public void MovingStopsAtThePageEdges()
    {
        Assert.Equal(new Rect(0, 0, 60, 30), RedactBoxEditor.Drag(Box, RedactBoxEditor.Handle.Body, new Vector(-500, -500), Page));
        Assert.Equal(new Rect(140, 70, 60, 30), RedactBoxEditor.Drag(Box, RedactBoxEditor.Handle.Body, new Vector(500, 500), Page));
    }

    [Fact]
    public void ResizingStopsAtThePageEdges()
    {
        Assert.Equal(new Rect(0, 0, 110, 70), RedactBoxEditor.Drag(Box, RedactBoxEditor.Handle.TopLeft, new Vector(-500, -500), Page));
        Assert.Equal(new Rect(50, 40, 150, 60), RedactBoxEditor.Drag(Box, RedactBoxEditor.Handle.BottomRight, new Vector(500, 500), Page));
    }

    [Fact]
    public void ResizingKeepsTheMinimumAndDoesNotFlip()
    {
        Assert.Equal(new Rect(106, 40, 4, 30), RedactBoxEditor.Drag(Box, RedactBoxEditor.Handle.Left, new Vector(500, 0), Page));
        Assert.Equal(new Rect(50, 40, 60, 4), RedactBoxEditor.Drag(Box, RedactBoxEditor.Handle.Bottom, new Vector(0, -500), Page));
    }
}
