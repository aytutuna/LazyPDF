using System.Windows;
using Xunit;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tests;

public sealed class PageOverlayTests
{
    private static readonly Size Page = new(200, 300);

    [Theory]
    [InlineData(0, 10, 20, 100, 40)]
    [InlineData(90, 40, -10, 40, 100)]
    [InlineData(180, 10, 20, 100, 40)]
    [InlineData(270, 40, -10, 40, 100)]
    public void TheFootprintKeepsTheCentreAndSwapsAtASideways(int rotation, double x, double y, double w, double h)
    {
        var bounds = PageOverlay.UprightBounds(new Rect(10, 20, 100, 40), rotation);

        Assert.Equal(new Rect(x, y, w, h), bounds);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void APlacedBoxLiesInThePage(int rotation)
    {
        foreach (var box in new[] { new Rect(-30, -30, 80, 20), new Rect(190, 290, 80, 20), new Rect(150, 10, 80, 20), new Rect(5, 280, 80, 20) })
        {
            var bounds = PageOverlay.UprightBounds(PageOverlay.Place(box, Page, rotation), rotation);

            Assert.True(bounds.Left >= 0 && bounds.Top >= 0 && bounds.Right <= 200 && bounds.Bottom <= 300, $"{box} at {rotation}: {bounds}");
        }
    }

    [Fact]
    public void ABoxThatFitsDoesNotMove()
    {
        var box = new Rect(60, 100, 80, 20);

        Assert.Equal(box, PageOverlay.Place(box, Page, 0));
        Assert.Equal(box, PageOverlay.Place(box, Page, 180));
    }

    [Theory]
    [InlineData(0, 0, 0)]
    [InlineData(90, 0, -50)]
    [InlineData(180, -150, -50)]
    [InlineData(270, -150, 0)]
    public void AFootprintThatDoesNotFitStartsAtTheScreenTopLeft(int rotation, double left, double top)
    {
        var bounds = PageOverlay.UprightBounds(PageOverlay.Place(new Rect(40, 20, 350, 350), Page, rotation), rotation);

        Assert.Equal(left, bounds.Left);
        Assert.Equal(top, bounds.Top);
    }

    [Theory]
    [InlineData(0, 150, 270)]
    [InlineData(90, 80, 120)]
    [InlineData(180, 130, 50)]
    [InlineData(270, 300, 100)]
    public void TheRoomRunsFromTheScreenTopLeftToTheEdges(int rotation, double width, double height)
    {
        var room = PageOverlay.Room(new Rect(50, 30, 80, 20), Page, rotation);

        Assert.Equal(new Size(width, height), room);
    }
}
